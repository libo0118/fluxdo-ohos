import 'dart:async';
import 'dart:io';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:test/test.dart';

void main() {
  final uri = Uri.parse('https://linux.do');
  late Directory directory;
  late _BlockingStore store;
  late EnhancedPersistCookieJar jar;
  var generation = 0;

  Cookie token(String value) => Cookie('_t', value)
    ..path = '/'
    ..secure = true
    ..httpOnly = true
    ..expires = DateTime.utc(2098);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('guarded_cookie_save_');
    store = _BlockingStore(directory.path);
    jar = EnhancedPersistCookieJar(store: store);
    generation = 0;
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('old save queued after logout cleanup cannot recreate credentials', () async {
    await jar.saveFromResponse(uri, [token('old')]);
    final writesBeforeLogout = store.writes;
    store.deleteRelease = Completer<void>();
    final deleting = jar.deleteAll();
    await store.deleteStarted.future;
    final requestGeneration = generation;
    final saving = jar.saveFromResponseGuarded(
      uri,
      [token('late')],
      isCurrent: () => requestGeneration == generation,
      trusted: true,
    );
    generation++;
    store.deleteRelease!.complete();
    await deleting;

    expect(await saving, isFalse);
    expect(await jar.readAllCookies(), isEmpty);
    expect(store.writes, writesBeforeLogout);
    expect(
      await EnhancedPersistCookieJar(store: FileCookieStore(directory.path)).readAllCookies(),
      isEmpty,
    );
  });

  test('generation change while reading storage prevents memory and disk writes', () async {
    store.readRelease = Completer<void>();
    final requestGeneration = generation;
    final saving = jar.saveFromResponseGuarded(
      uri,
      [token('late')],
      isCurrent: () => requestGeneration == generation,
    );
    await store.readStarted.future;
    generation++;
    store.readRelease!.complete();

    expect(await saving, isFalse);
    expect(await jar.readAllCookies(), isEmpty);
    expect(store.writes, 0);
    expect(await File('${directory.path}/cookies.v1.json').exists(), isFalse);
  });

  test('valid guarded trusted save preserves normal version arbitration', () async {
    await jar.saveFromResponseTrusted(uri, [token('old')], trusted: true);
    final before = (await jar.readAllCookies()).single;
    expect(
      await jar.saveFromResponseGuarded(
        uri,
        [token('new')],
        isCurrent: () => true,
        trusted: true,
      ),
      isTrue,
    );
    final after = (await jar.readAllCookies()).single;
    expect(after.value, 'new');
    expect(after.version, before.version + 1);
    expect(after.creationTime, before.creationTime);
  });

  test('old auth replacement queued after cleanup cannot recreate its winner', () async {
    await jar.saveFromResponse(uri, [token('old')]);
    final replacement = (await jar.readAllCookies()).single;
    store.deleteRelease = Completer<void>();
    final deleting = jar.deleteAll();
    await store.deleteStarted.future;
    final requestGeneration = generation;
    final replacing = jar.replaceByNameForSite(
      uri,
      '_t',
      [replacement],
      isCurrent: () => requestGeneration == generation,
    );
    generation++;
    store.deleteRelease!.complete();
    await deleting;

    expect(await replacing, 0);
    expect(await jar.readAllCookies(), isEmpty);
    expect(await File('${directory.path}/cookies.v1.json').exists(), isFalse);
  });

  test('auth replacement rechecks its generation after a pending storage read', () async {
    store.readRelease = Completer<void>();
    final requestGeneration = generation;
    final replacing = jar.replaceByNameForSite(
      uri,
      '_t',
      [SetCookieParser.fromIoCookie(token('late'), uri: uri)],
      isCurrent: () => requestGeneration == generation,
    );
    await store.readStarted.future;
    generation++;
    store.readRelease!.complete();

    expect(await replacing, 0);
    expect(await jar.readAllCookies(), isEmpty);
    expect(store.writes, 0);
  });

  test('logout queued after an authorized write still wins final cleanup', () async {
    store.writeRelease = Completer<void>();
    final requestGeneration = generation;
    final saving = jar.saveFromResponseGuarded(
      uri,
      [token('old')],
      isCurrent: () => requestGeneration == generation,
    );
    await store.writeStarted.future;
    generation++;
    final deleting = jar.deleteAll();
    store.writeRelease!.complete();

    expect(await saving, isTrue);
    await deleting;
    expect(await jar.readAllCookies(), isEmpty);
    expect(
      await EnhancedPersistCookieJar(store: FileCookieStore(directory.path)).readAllCookies(),
      isEmpty,
    );
  });
}

class _BlockingStore extends FileCookieStore {
  _BlockingStore(super.directoryPath);

  Completer<void>? readRelease;
  Completer<void>? writeRelease;
  Completer<void>? deleteRelease;
  final readStarted = Completer<void>();
  final writeStarted = Completer<void>();
  final deleteStarted = Completer<void>();
  int writes = 0;

  @override
  Future<List<CanonicalCookie>> readAll() async {
    if (readRelease != null) {
      if (!readStarted.isCompleted) readStarted.complete();
      await readRelease!.future;
    }
    return super.readAll();
  }

  @override
  Future<void> writeAll(List<CanonicalCookie> cookies) async {
    writes++;
    if (writeRelease != null) {
      if (!writeStarted.isCompleted) writeStarted.complete();
      await writeRelease!.future;
    }
    await super.writeAll(cookies);
  }

  @override
  Future<void> deleteAll() async {
    if (deleteRelease != null) {
      if (!deleteStarted.isCompleted) deleteStarted.complete();
      await deleteRelease!.future;
    }
    await super.deleteAll();
  }
}
