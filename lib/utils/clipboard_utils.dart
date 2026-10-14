import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

import '../services/public_file_channel.dart';
import 'image_transfer_utils.dart';

/// 原始图片格式和 HTML 保持独立，供现有编辑器决定粘贴优先级。
class OhosClipboardContent {
  const OhosClipboardContent({this.html, this.text, this.image, this.extension});

  final String? html;
  final String? text;
  final Uint8List? image;
  final String? extension;
}

abstract final class ClipboardUtils {
  static bool get isOhos => PublicFileChannel.isOhos;

  static Future<OhosClipboardContent> readOhos() async {
    final value = await PublicFileChannel.readClipboard();
    final mime = value?['mimeType'] as String?;
    var image = value?['bytes'] as Uint8List?;
    var extension = switch (mime) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => null,
    };
    if (image != null && (mime == 'image/avif' || mime == 'image/svg+xml')) {
      final converted = await prepareSystemImage(image, expectedMimeType: mime);
      image = converted.$1;
      extension = converted.$2;
    }
    return OhosClipboardContent(
      html: value?['html'] as String?,
      text: value?['text'] as String?,
      image: image,
      extension: extension,
    );
  }

  static Future<void> writeImage(Uint8List bytes) async {
    if (isOhos) {
      final (data, extension) = await prepareSystemImage(bytes);
      final mime = extension == 'jpg' ? 'image/jpeg' : 'image/$extension';
      await PublicFileChannel.writeClipboardImage(data, mime);
      return;
    }
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) throw StateError('System clipboard unavailable');
    final item = DataWriterItem();
    item.add(Formats.png(bytes));
    await clipboard.write([item]);
  }
}
