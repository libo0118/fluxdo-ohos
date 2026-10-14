import 'dart:ffi';
import 'dart:io';

import 'flutter_avif_bridge.io.dart';

FlutterAvif? _api;

FlutterAvif? get ohosApi {
  if (Platform.operatingSystem != 'ohos') return null;
  return _api ??= FlutterAvifImpl(DynamicLibrary.open('libflutter_avif.so'));
}
