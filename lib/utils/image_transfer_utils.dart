import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:jovial_svg/jovial_svg.dart';

import '../services/avif_image_provider.dart';
import 'svg_utils.dart';

/// 系统剪贴板/图库可直接接收的格式保留原字节，其余位图只导出当前首帧。
Future<(Uint8List, String)> prepareSystemImage(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
    throw const FormatException('Image data is empty or too large');
  }
  if (bytes.length >= 8 && bytes[0] == 0x89 &&
      String.fromCharCodes(bytes.sublist(1, 4)) == 'PNG') return (bytes, 'png');
  if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) return (bytes, 'jpg');
  if (bytes.length >= 6 && String.fromCharCodes(bytes.sublist(0, 6)).startsWith('GIF8')) return (bytes, 'gif');
  if (bytes.length >= 12 && String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') return (bytes, 'webp');

  if (SvgUtils.isSvgBytes(bytes)) {
    if (bytes.length > 4 * 1024 * 1024) throw const FormatException('SVG data is too large');
    final si = ScalableImage.fromSvgString(
      SvgUtils.sanitize(SvgUtils.stripActiveContent(SvgUtils.decodeSvgBytes(bytes))),
      warnF: (_) {},
    );
    final viewport = si.viewport;
    if (!viewport.width.isFinite || !viewport.height.isFinite ||
        viewport.width <= 0 || viewport.height <= 0 ||
        viewport.width > 8192 || viewport.height > 8192 ||
        viewport.width.ceil() * viewport.height.ceil() > 16 * 1024 * 1024) {
      throw const FormatException('SVG image dimensions are invalid or too large');
    }
    final recorder = ui.PictureRecorder();
    ui.Picture? picture;
    ui.Image? raster;
    try {
      await si.prepareImages().timeout(const Duration(seconds: 15));
      si.paint(ui.Canvas(recorder));
      picture = recorder.endRecording();
      raster = await picture.toImage(viewport.width.ceil(), viewport.height.ceil());
      return (await _png(raster), 'png');
    } finally {
      if (recorder.isRecording) recorder.endRecording().dispose();
      raster?.dispose();
      picture?.dispose();
      si.unprepareImages();
    }
  }

  if (_isAvif(bytes)) {
    // 系统传输位图最多 4096px；原始 AVIF 文件和应用显示管线保持原样。
    final raster = await AvifImageProvider.decodeFirstFrame(bytes, maxDim: 4096);
    try {
      if (raster.width <= 0 || raster.height <= 0 ||
          raster.width * raster.height > 16 * 1024 * 1024) {
        throw const FormatException('AVIF image dimensions are invalid or too large');
      }
      return (await _png(raster), 'png');
    } finally { raster.dispose(); }
  }

  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? raster;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width <= 0 || descriptor.height <= 0 ||
        descriptor.width > 8192 || descriptor.height > 8192 ||
        descriptor.width * descriptor.height > 16 * 1024 * 1024) {
      throw const FormatException('Image dimensions are invalid or too large');
    }
    codec = await descriptor.instantiateCodec();
    raster = (await codec.getNextFrame()).image;
    return (await _png(raster), 'png');
  } finally {
    raster?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

bool _isAvif(Uint8List bytes) {
  if (bytes.length < 16 || String.fromCharCodes(bytes.sublist(4, 8)) != 'ftyp') return false;
  final length = ByteData.sublistView(bytes).getUint32(0, Endian.big);
  if (length < 16 || length > bytes.length || length > 4096) return false;
  for (var offset = 8; offset + 4 <= length; offset += 4) {
    if (offset == 12) continue; // ISO BMFF minor_version 不是兼容格式标识。
    final brand = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (brand == 'avif' || brand == 'avis') return true;
  }
  return false;
}

Future<Uint8List> _png(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null || data.lengthInBytes == 0) throw StateError('Image encoding failed');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
