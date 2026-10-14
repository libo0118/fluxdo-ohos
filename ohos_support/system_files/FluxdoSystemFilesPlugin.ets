import { common, abilityAccessCtrl, wantConstant } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import picker from '@ohos.file.picker';
import fileShare from '@ohos.fileshare';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import pasteboard from '@ohos.pasteboard';
import image from '@ohos.multimedia.image';
import util from '@ohos.util';
import utd from '@ohos.data.uniformTypeDescriptor';
import systemShare from '@hms.collaboration.systemShare';
import { MethodCall, MethodChannel } from '@ohos/flutter_ohos';
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';

const IMAGE_TYPES: Array<string> = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];
const READ_IMAGE_TYPES: Array<string> = IMAGE_TYPES.concat(['image/avif', 'image/svg+xml']);

class FilesError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

export default class FluxdoSystemFilesPlugin implements FlutterPlugin, MethodCallHandler {
  static abilityContext: common.UIAbilityContext | null = null;
  private channel: MethodChannel | null = null;
  private picking: boolean = false;
  private clipboardBusy: boolean = false;
  private sharing: boolean = false;
  private shareController: systemShare.ShareController | null = null;

  getUniqueClassName(): string { return 'FluxdoSystemFilesPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.fluxdo/public_file');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  private context(): common.UIAbilityContext {
    const context = FluxdoSystemFilesPlugin.abilityContext;
    if (context === null) throw new FilesError('NO_ACTIVITY', '未连接应用界面。');
    return context;
  }

  private stringArg(call: MethodCall, key: string): string {
    const value: Object | null = call.argument(key);
    if (typeof value !== 'string' || value.length === 0 || value.includes('\0')) {
      throw new FilesError('INVALID_ARGS', '文件参数无效。');
    }
    return value;
  }

  private fileName(value: string): string {
    const name = value.replace(/[\\/:*?"'`<>|{}\[\]\x00-\x1f]/g, '_').trim();
    if (name.length === 0 || name === '.' || name === '..' || name.length > 255) {
      throw new FilesError('INVALID_ARGS', '文件名无效。');
    }
    return name;
  }

  private uri(value: string): string {
    if (value.startsWith('/')) return fileUri.getUriFromPath(value);
    if (value.startsWith('file://')) return value;
    throw new FilesError('INVALID_ARGS', '仅支持本机文件 URI。');
  }

  private async copy(source: string, destination: string): Promise<void> {
    let input: fs.File | null = null;
    let output: fs.File | null = null;
    try {
      input = await fs.open(source, fs.OpenMode.READ_ONLY);
      output = await fs.open(destination, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      await fs.copyFile(input.fd, output.fd);
    } finally {
      try { if (output !== null) await fs.close(output); }
      finally { if (input !== null) await fs.close(input); }
    }
  }

  private async save(call: MethodCall): Promise<Map<string, Object> | null> {
    if (this.picking) throw new FilesError('BUSY', '已有保存窗口。');
    const source = this.stringArg(call, 'sourcePath');
    if (!source.startsWith('/')) throw new FilesError('INVALID_ARGS', '保存源必须是本地文件路径。');
    const name = this.fileName(this.stringArg(call, 'fileName'));
    const context = this.context();
    this.picking = true;
    try {
      const selected = await new picker.DocumentViewPicker(context).save({ newFileNames: [name] });
      if (selected.length === 0) return null;
      const target = this.uri(selected[0]);
      await this.copy(source, target);
      const displayName = this.fileName(new fileUri.FileUri(target).name || name);
      let historyRef = target;
      try {
        await fileShare.persistPermission([{ uri: target, operationMode: fileShare.OperationMode.READ_MODE }]);
      } catch (error) {
        // Picker 临时授权可能在重启后失效；导出历史必须有独立持久副本。
        const directory = `${context.filesDir}/export_history`;
        if (!await fs.access(directory)) await fs.mkdir(directory, true);
        historyRef = `${directory}/${Date.now()}_${Math.floor(Math.random() * 1000000)}_${displayName}`;
        await fs.copyFile(source, historyRef);
      }
      return new Map<string, Object>([['uri', historyRef], ['displayName', displayName]]);
    } finally { this.picking = false; }
  }

  private async saveImage(call: MethodCall): Promise<boolean> {
    if (this.picking) throw new FilesError('BUSY', '已有保存窗口。');
    const source = this.stringArg(call, 'sourcePath');
    if (!source.startsWith('/')) throw new FilesError('INVALID_ARGS', '图片源必须是本地文件路径。');
    const name = this.fileName(this.stringArg(call, 'fileName'));
    const dot = name.lastIndexOf('.');
    if (dot < 1) throw new FilesError('INVALID_ARGS', '图片文件需要扩展名。');
    const context = this.context();
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    this.picking = true;
    try {
      const config: photoAccessHelper.PhotoCreationConfig = {
        title: name.substring(0, dot), fileNameExtension: name.substring(dot + 1),
        photoType: photoAccessHelper.PhotoType.IMAGE,
      };
      const targets = await helper.showAssetsCreationDialog([fileUri.getUriFromPath(source)], [config]);
      if (targets.length === 0) return false;
      await this.copy(source, this.uri(targets[0]));
      return true;
    } finally {
      try { await helper.release(); }
      finally { this.picking = false; }
    }
  }

  private type(uri: string, mime: Object | null): string {
    if (typeof mime === 'string' && mime.length > 0) return utd.getUniformDataTypeByMIMEType(mime);
    const dot = uri.lastIndexOf('.');
    return dot >= 0 ? utd.getUniformDataTypeByFilenameExtension(uri.substring(dot)) : utd.UniformDataType.FILE;
  }

  private async open(call: MethodCall): Promise<boolean> {
    const uri = this.uri(this.stringArg(call, 'uri'));
    await this.restorePermission(uri);
    await this.context().startAbility({
      action: 'ohos.want.action.viewData', uri: uri,
      type: this.type(uri, call.argument('mimeType')),
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
    });
    return true;
  }

  private async restorePermission(uri: string): Promise<void> {
    if (!uri.startsWith('file://docs/')) return;
    const policies: Array<fileShare.PolicyInfo> = [{ uri: uri, operationMode: fileShare.OperationMode.READ_MODE }];
    const persistent = await fileShare.checkPersistentPermission(policies);
    if (persistent[0]) await fileShare.activatePermission(policies);
  }

  private async share(call: MethodCall): Promise<boolean> {
    if (this.sharing) throw new FilesError('BUSY', '已有分享窗口。');
    const context = this.context();
    const text = call.method === 'shareText' ? this.stringArg(call, 'text') : null;
    const uri = text === null ? this.uri(this.stringArg(call, 'uri')) : null;
    this.sharing = true;
    try {
      if (uri !== null) await this.restorePermission(uri);
      const record: systemShare.SharedRecord = uri !== null
        ? { utd: this.type(uri, call.argument('mimeType')), uri: uri }
        : { utd: utd.UniformDataType.PLAIN_TEXT, content: text ?? '' };
      const subject: Object | null = call.argument('subject');
      if (typeof subject === 'string' && subject.length > 0) record.title = subject;
      const controller = new systemShare.ShareController(new systemShare.SharedData(record));
      const dismiss = (): void => {
        if (this.shareController !== controller) return;
        controller.off('dismiss', dismiss);
        this.shareController = null;
        this.sharing = false;
      };
      this.shareController = controller;
      controller.on('dismiss', dismiss);
      try {
        await controller.show(context, {
          selectionMode: systemShare.SelectionMode.SINGLE,
          previewMode: systemShare.SharePreviewMode.DEFAULT,
        });
      } catch (error) { dismiss(); throw error as Error; }
      // 仅表示系统分享面板已显示，不表示接收应用完成接收。
      return true;
    } catch (error) {
      this.shareController = null;
      this.sharing = false;
      throw error as Error;
    }
  }

  private async readClipboard(): Promise<Map<string, Object>> {
    const permission = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(
      this.context(), ['ohos.permission.READ_PASTEBOARD']);
    if (permission.authResults[0] !== 0) throw new FilesError('PERMISSION_DENIED', '未授权读取剪贴板。');
    const data = await pasteboard.getSystemPasteboard().getData();
    const values = new Map<string, Object>();
    const types = READ_IMAGE_TYPES.concat([pasteboard.MIMETYPE_TEXT_HTML, pasteboard.MIMETYPE_TEXT_PLAIN, pasteboard.MIMETYPE_PIXELMAP]);
    for (let index = 0; index < data.getRecordCount(); index++) {
      const record = data.getRecord(index);
      const present = record.getValidTypes(types);
      for (const type of present) {
        const value = await record.getData(type);
        if (type === pasteboard.MIMETYPE_TEXT_HTML && typeof value === 'string' && !values.has('html')) values.set('html', value);
        else if (type === pasteboard.MIMETYPE_TEXT_PLAIN && typeof value === 'string' && !values.has('text')) values.set('text', value);
        else if (READ_IMAGE_TYPES.includes(type) && !values.has('bytes')) {
          let bytes: Uint8Array | null = null;
          if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
          else if (type === 'image/svg+xml' && typeof value === 'string') {
            if (value.length > 4 * 1024 * 1024) throw new FilesError('IMAGE_TOO_LARGE', '剪贴板图片过大。');
            bytes = new util.TextEncoder().encodeInto(value);
          }
          if (bytes !== null) {
            const limit = type === 'image/svg+xml' ? 4 * 1024 * 1024 : 32 * 1024 * 1024;
            if (bytes.length === 0 || bytes.length > limit) throw new FilesError('INVALID_ARGS', '剪贴板图片大小无效。');
            values.set('bytes', bytes); values.set('mimeType', type);
          }
        }
      }
    }
    if (!values.has('bytes')) {
      for (let index = 0; index < data.getRecordCount(); index++) {
        const record = data.getRecord(index);
        if (!record.getValidTypes([pasteboard.MIMETYPE_PIXELMAP]).includes(pasteboard.MIMETYPE_PIXELMAP)) continue;
        const pixel = await record.getData(pasteboard.MIMETYPE_PIXELMAP) as image.PixelMap;
        const packer = image.createImagePacker();
        try {
          this.checkImageSize(await pixel.getImageInfo());
          values.set('bytes', new Uint8Array(await packer.packing(pixel, { format: 'image/png', quality: 100 })));
          values.set('mimeType', 'image/png');
        } finally {
          try { await packer.release(); }
          finally { await pixel.release(); }
        }
        break;
      }
    }
    return values;
  }

  private async writeClipboard(call: MethodCall): Promise<void> {
    const bytes: Object | null = call.argument('bytes');
    const mime = this.stringArg(call, 'mimeType');
    if (!(bytes instanceof Uint8Array) || bytes.length === 0 || !IMAGE_TYPES.includes(mime)) {
      throw new FilesError('INVALID_ARGS', '剪贴板图片无效。');
    }
    const buffer = new Uint8Array(bytes).buffer;
    const source = image.createImageSource(buffer);
    let pixel: image.PixelMap | null = null;
    try {
      this.checkImageSize(await source.getImageInfo());
      pixel = await source.createPixelMap();
      const data = pasteboard.createData(mime, buffer);
      data.addRecord(pasteboard.MIMETYPE_PIXELMAP, pixel);
      await pasteboard.getSystemPasteboard().setData(data);
    } finally {
      try { await pixel?.release(); }
      finally { await source.release(); }
    }
  }

  private checkImageSize(info: image.ImageInfo): void {
    const width = info.size.width;
    const height = info.size.height;
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192 || width * height > 16 * 1024 * 1024) {
      throw new FilesError('IMAGE_TOO_LARGE', '图片尺寸无效或过大。');
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.dispatch(call, result).catch((error: Error): void => {
      result.error(error instanceof FilesError ? error.code : 'FILE_OPERATION_FAILED', '系统文件操作失败。', null);
    });
  }

  private async dispatch(call: MethodCall, result: MethodResult): Promise<void> {
    switch (call.method) {
      case 'saveToDownloads': result.success(null); break;
      case 'saveAs': result.success(await this.save(call)); break;
      case 'saveImageToGallery': result.success(await this.saveImage(call)); break;
      case 'openUri': result.success(await this.open(call)); break;
      case 'shareUri': case 'shareText': result.success(await this.share(call)); break;
      case 'readClipboard': case 'writeClipboardImage':
        if (this.clipboardBusy) throw new FilesError('BUSY', '已有剪贴板操作。');
        this.clipboardBusy = true;
        try {
          if (call.method === 'readClipboard') result.success(await this.readClipboard());
          else { await this.writeClipboard(call); result.success(null); }
        } finally { this.clipboardBusy = false; }
        break;
      default: result.notImplemented();
    }
  }
}
