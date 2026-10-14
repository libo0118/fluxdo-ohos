import { common } from '@kit.AbilityKit';
import { asset } from '@kit.AssetStoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { MethodCall, MethodChannel } from '@ohos/flutter_ohos';
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';

interface EncryptedRecord {
  schema: number;
  iv: string;
  authTag: string;
  id: string;
  chunks: number;
}

const STORE_NAME = 'fluxdo_secure_storage_v1';
const KEY_ALIAS = 'fluxdo.secure_storage.aes256.v1';
const RECORD_PREFIX = 'r:';
const CHUNK_PREFIX = 'c:';
// Preferences 单个字符串有长度限制，密文分块支持 CA 和长配置。
const CHUNK_SIZE = 4096;

export class AssetProtectedStore {
  private readonly encoder: util.TextEncoder = new util.TextEncoder();
  private readonly base64: util.Base64Helper = new util.Base64Helper();
  private readonly source: preferences.Preferences;

  constructor(context: common.Context) {
    this.source = preferences.getPreferencesSync(context, { name: STORE_NAME });
  }

  private encode(text: string): Uint8Array {
    return this.encoder.encodeInto(text);
  }

  private decode(text: string): Uint8Array {
    const bytes = this.base64.decodeSync(text);
    if (this.base64.encodeToStringSync(bytes) !== text) {
      throw new Error('安全存储记录的 Base64 无效');
    }
    return bytes;
  }

  private recordKey(key: string): string {
    return RECORD_PREFIX + this.base64.encodeToStringSync(this.encode(key));
  }

  private chunkKey(id: string, index: number): string {
    return CHUNK_PREFIX + id + ':' + index;
  }

  private all(): Record<string, preferences.ValueType> {
    return this.source.getAllSync() as Record<string, preferences.ValueType>;
  }

  private record(key: string): EncryptedRecord | null {
    const name = this.recordKey(key);
    if (!this.source.hasSync(name)) return null;
    const raw = this.source.getSync(name, '');
    if (typeof raw !== 'string') throw new Error('安全存储记录类型无效');
    const record = JSON.parse(raw) as EncryptedRecord;
    if (record === null || record.schema !== 1 || typeof record.iv !== 'string' ||
      typeof record.authTag !== 'string' || typeof record.id !== 'string' ||
      !/^[A-Za-z0-9+/]{16}$/.test(record.id) ||
      !Number.isSafeInteger(record.chunks) || record.chunks < 1 ||
      record.chunks > Object.keys(this.all()).length ||
      this.decode(record.iv).length !== 12 || this.decode(record.authTag).length !== 16) {
      throw new Error('安全存储记录损坏或版本不受支持');
    }
    return record;
  }

  private queryKey(): Promise<Array<asset.AssetMap>> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.encode(KEY_ALIAS));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    return asset.query(query);
  }

  async key(): Promise<cryptoFramework.SymKey> {
    let found: Array<asset.AssetMap>;
    try {
      found = await this.queryKey();
    } catch (error) {
      if ((error as BusinessError).code !== 24000002) throw error as Error;
      if (Object.keys(this.all()).some((name: string) => name.startsWith(RECORD_PREFIX))) {
        // 密钥丢失时拒绝生成替代密钥，避免把旧密文永久覆盖。
        throw new Error('系统安全存储密钥丢失');
      }
      const bytes = (await cryptoFramework.createRandom().generateRandom(32)).data;
      const attributes: asset.AssetMap = new Map();
      attributes.set(asset.Tag.ALIAS, this.encode(KEY_ALIAS));
      attributes.set(asset.Tag.SECRET, bytes);
      attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
      attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.THROW_ERROR);
      try {
        await asset.add(attributes);
      } catch (addError) {
        // 跨引擎首次写入竞争时复用胜出的系统密钥，绝不覆盖。
        if ((addError as BusinessError).code !== 24000003) throw addError as Error;
      } finally {
        bytes.fill(0);
      }
      found = await this.queryKey();
    }
    if (found.length !== 1) throw new Error('系统安全存储密钥数量无效');
    const secret = found[0].get(asset.Tag.SECRET);
    if (!(secret instanceof Uint8Array) || secret.length !== 32) {
      throw new Error('系统安全存储密钥无效');
    }
    try {
      return await cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: secret });
    } finally {
      secret.fill(0);
    }
  }

  private params(key: string, iv: Uint8Array, tag: Uint8Array): cryptoFramework.GcmParamsSpec {
    return {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: this.encode(JSON.stringify([STORE_NAME, key, 1])) },
      authTag: { data: tag }
    };
  }

  async read(key: string, secret: cryptoFramework.SymKey): Promise<string | null> {
    const record = this.record(key);
    if (record === null) return null;
    let encoded = '';
    for (let index = 0; index < record.chunks; index++) {
      const name = this.chunkKey(record.id, index);
      if (!this.source.hasSync(name)) throw new Error('安全存储密文分块丢失');
      const chunk = this.source.getSync(name, '');
      if (typeof chunk !== 'string' || chunk.length > CHUNK_SIZE ||
        (index < record.chunks - 1 && chunk.length !== CHUNK_SIZE)) {
        throw new Error('安全存储密文分块无效');
      }
      encoded += chunk;
    }
    const ciphertext = this.decode(encoded);
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, secret,
      this.params(key, this.decode(record.iv), this.decode(record.authTag)));
    // doFinal 必须完成认证后才能把明文交还给 Dart，包括空字符串。
    const plaintext = await cipher.doFinal(ciphertext.length === 0 ? null : { data: ciphertext });
    if (plaintext === null) {
      if (ciphertext.length !== 0) throw new Error('安全存储解密结果无效');
      return '';
    }
    try {
      return util.TextDecoder.create('utf-8').decodeToString(plaintext.data);
    } finally {
      plaintext.data.fill(0);
    }
  }

  async write(key: string, value: string, secret: cryptoFramework.SymKey): Promise<void> {
    const previous = this.record(key);
    if (previous !== null) await this.read(key, secret);
    const name = this.recordKey(key);
    const previousRaw = previous === null ? null : this.source.getSync(name, '') as string;
    const iv = (await cryptoFramework.createRandom().generateRandom(12)).data;
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, secret,
      this.params(key, iv, new Uint8Array(16)));
    const plaintext = this.encode(value);
    let encrypted: cryptoFramework.DataBlob;
    try {
      encrypted = await cipher.doFinal(plaintext.length === 0 ? null : { data: plaintext });
    } finally {
      plaintext.fill(0);
    }
    if (encrypted === null || encrypted.data.length < 16) {
      throw new Error('安全存储加密结果无效');
    }
    const length = encrypted.data.length;
    const ciphertext = this.base64.encodeToStringSync(encrypted.data.slice(0, length - 16));
    const id = this.base64.encodeToStringSync((await cryptoFramework.createRandom().generateRandom(12)).data);
    const record: EncryptedRecord = {
      schema: 1,
      iv: this.base64.encodeToStringSync(iv),
      authTag: this.base64.encodeToStringSync(encrypted.data.slice(length - 16)),
      id: id,
      chunks: Math.max(1, Math.ceil(ciphertext.length / CHUNK_SIZE))
    };
    try {
      for (let index = 0; index < record.chunks; index++) {
        this.source.putSync(this.chunkKey(id, index), ciphertext.slice(index * CHUNK_SIZE, (index + 1) * CHUNK_SIZE));
      }
      // 先落盘新分块，再提交索引，旧索引始终指向完整密文。
      await this.source.flush();
      this.source.putSync(name, JSON.stringify(record));
      await this.source.flush();
    } catch (error) {
      if (previousRaw === null) this.source.deleteSync(name);
      else this.source.putSync(name, previousRaw);
      for (let index = 0; index < record.chunks; index++) {
        this.source.deleteSync(this.chunkKey(id, index));
      }
      // 恢复内存和持久索引；恢复也失败时仍向调用方报错。
      await this.source.flush();
      throw error as Error;
    }
    if (previous !== null) {
      for (let index = 0; index < previous.chunks; index++) {
        this.source.deleteSync(this.chunkKey(previous.id, index));
      }
      await this.source.flush();
    }
  }

  async delete(key: string, secret: cryptoFramework.SymKey): Promise<void> {
    const previous = this.record(key);
    if (previous === null) return;
    await this.read(key, secret);
    const name = this.recordKey(key);
    const previousRaw = this.source.getSync(name, '') as string;
    this.source.deleteSync(name);
    try {
      await this.source.flush();
    } catch (error) {
      this.source.putSync(name, previousRaw);
      await this.source.flush();
      throw error as Error;
    }
    for (let index = 0; index < previous.chunks; index++) {
      this.source.deleteSync(this.chunkKey(previous.id, index));
    }
    await this.source.flush();
  }

  async deleteAll(): Promise<void> {
    const previous = this.all();
    this.source.clearSync();
    // 不删除系统 AES 密钥，避免其他引擎持有旧密钥时产生不可读记录。
    try {
      await this.source.flush();
    } catch (error) {
      for (const name of Object.keys(previous)) this.source.putSync(name, previous[name]);
      await this.source.flush();
      throw error as Error;
    }
  }

  async readAll(secret: cryptoFramework.SymKey): Promise<Map<string, string>> {
    const result = new Map<string, string>();
    for (const name of Object.keys(this.all())) {
      if (!name.startsWith(RECORD_PREFIX)) continue;
      const key = util.TextDecoder.create('utf-8').decodeToString(this.decode(name.slice(RECORD_PREFIX.length)));
      const value = await this.read(key, secret);
      if (value === null) throw new Error('安全存储记录在读取期间丢失');
      result.set(key, value);
    }
    return result;
  }
}

export default class FluxdoSecureStoragePlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.Context | null = null;
  private store: AssetProtectedStore | null = null;
  // 同一进程内所有引擎共用队列，避免 Preferences 缓存和首次密钥初始化交叉。
  private static pending: Promise<void> = Promise.resolve();

  getUniqueClassName(): string {
    return 'FluxdoSecureStoragePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'plugins.it_nomads.com/flutter_secure_storage');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.context = null;
    this.store = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (!['write', 'read', 'delete', 'deleteAll', 'containsKey', 'readAll'].includes(call.method)) {
      result.notImplemented();
      return;
    }
    const context = this.context;
    const task = FluxdoSecureStoragePlugin.pending.then(async (): Promise<void> => {
      try {
        if (context === null) throw new Error('安全存储插件未连接');
        if (this.store === null) this.store = new AssetProtectedStore(context);
        const store = this.store;
        const secret = await store.key();
        try {
          if (call.method === 'readAll') {
            result.success(await store.readAll(secret));
          } else if (call.method === 'deleteAll') {
            await store.deleteAll();
            result.success(null);
          } else {
            const key: Object | null = call.argument('key');
            if (typeof key !== 'string') throw new Error('安全存储 key 必须为字符串');
            switch (call.method) {
              case 'read':
                result.success(await store.read(key, secret));
                break;
              case 'containsKey':
                result.success((await store.read(key, secret)) !== null);
                break;
              case 'delete':
                await store.delete(key, secret);
                result.success(null);
                break;
              case 'write':
                const value: Object | null = call.argument('value');
                if (value === null || value === undefined) {
                  await store.delete(key, secret);
                } else {
                  if (typeof value !== 'string') throw new Error('安全存储 value 必须为字符串');
                  await store.write(key, value, secret);
                }
                result.success(null);
                break;
            }
          }
        } finally {
          secret.clearMem();
        }
      } catch (error) {
        // 不将凭据、key、原生参数或原生异常文本写入日志/错误详情。
        result.error('secure_storage_error', '系统安全存储操作失败，未写入明文。', null);
      }
    });
    FluxdoSecureStoragePlugin.pending = task.catch((): void => {});
  }
}
