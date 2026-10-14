import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:fluxdo/utils/image_transfer_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PNG/JPEG/GIF/WebP 系统传输保留原字节和格式', () async {
    final cases = <(Uint8List, String)>[
      (Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]), 'png'),
      (Uint8List.fromList([255, 216, 255, 1]), 'jpg'),
      (Uint8List.fromList(ascii.encode('GIF89a')), 'gif'),
      (Uint8List.fromList(ascii.encode('RIFF0000WEBP')), 'webp'),
    ];
    for (final (bytes, expected) in cases) {
      final actual = await prepareSystemImage(bytes);
      expect(identical(actual.$1, bytes), isTrue);
      expect(actual.$2, expected);
    }
  });

  test('SVG 使用既有绘图库输出正确尺寸与像素的 PNG', () async {
    final bytes = Uint8List.fromList(utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="3" viewBox="0 0 4 3">'
      '<rect width="4" height="3" fill="#ff0000"/></svg>',
    ));
    final (png, extension) = await prepareSystemImage(bytes, expectedMimeType: 'image/svg+xml');
    expect(extension, 'png');
    final decoded = image.decodePng(png)!;
    expect((decoded.width, decoded.height), (4, 3));
    expect(decoded.getPixel(1, 1).r, 255);
    expect(decoded.getPixel(1, 1).g, 0);
    expect(decoded.getPixel(1, 1).a, 255);
  });

  test('剪贴板 AVIF/SVG 声明必须与真实文件格式一致', () async {
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]);
    for (final mime in ['image/avif', 'image/svg+xml']) {
      await expectLater(prepareSystemImage(png, expectedMimeType: mime), throwsFormatException);
    }
    final invalidAvif = Uint8List.fromList(ascii.encode('0000ftypavif0000'));
    await expectLater(prepareSystemImage(invalidAvif, expectedMimeType: 'image/avif'), throwsFormatException);
  });

  test('空数据、非法图片和过大 SVG 明确失败', () async {
    await expectLater(prepareSystemImage(Uint8List(0)), throwsFormatException);
    await expectLater(prepareSystemImage(Uint8List.fromList([1, 2, 3])), throwsA(anything));
    final large = Uint8List.fromList(utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" width="10000" height="10000">'
      '<rect width="10000" height="10000"/></svg>',
    ));
    await expectLater(prepareSystemImage(large), throwsFormatException);
  });
}
