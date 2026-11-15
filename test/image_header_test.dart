import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/image_header.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PNG size from IHDR', () {
    final png = _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0x02, 0xB2, 0, 0, 0x27, 0x10]);
    expect(encodedImageSize(png), (690, 10000));
  });

  test('GIF logical screen size', () {
    expect(encodedImageSize(_bytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0xD0, 0x02, 0x10, 0x27])),
      (720, 10000));
  });

  test('JPEG size skips APP segments to SOF0', () {
    final jpeg = _bytes([0xFF, 0xD8,
      0xFF, 0xE0, 0x00, 0x10, ...List.filled(14, 0), // APP0, 16 bytes
      0xFF, 0xE1, 0x00, 0x04, 0x00, 0x00, // APP1 (EXIF), 4 bytes
      0xFF, 0xC0, 0x00, 0x11, 0x08, 0x1F, 0xDB, 0x02, 0xB2, 0x03, // h=8155 w=690
      ...List.filled(12, 0)]);
    expect(encodedImageSize(jpeg), (690, 8155));
  });

  test('progressive JPEG (SOF2) and missing SOF', () {
    final sof2 = _bytes([0xFF, 0xD8, 0xFF, 0xC2, 0x00, 0x11, 0x08, 0x09, 0x00,
      0x02, 0xD0, 0x03, ...List.filled(12, 0)]);
    expect(encodedImageSize(sof2), (720, 2304));
    final noSof = _bytes([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x08, ...List.filled(12, 0)]);
    expect(encodedImageSize(noSof), isNull);
  });

  test('WebP VP8X canvas size', () {
    final webp = _bytes([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
      0x56, 0x50, 0x38, 0x58, 10, 0, 0, 0, 0, 0, 0, 0,
      0xCF, 0x02, 0x00, 0x0F, 0x27, 0x00]); // 719+1 x 9999+1
    expect(encodedImageSize(webp), (720, 10000));
  });

  test('unknown or truncated data is null', () {
    expect(encodedImageSize(_bytes([1, 2, 3])), isNull);
    expect(encodedImageSize(_bytes([0x89, 0x50, 0x4E, 0x47])), isNull);
  });

  test('predicted size equals what the real decoder produces', () async {
    // Mirrors ResizeImage.resizeIfNeeded(decodeWidth, null, …) exactly.
    Future<(int, int)> decoded(Uint8List png, int decodeWidth) async {
      final buffer = await ui.ImmutableBuffer.fromUint8List(png);
      final codec = await ui.instantiateImageCodecWithSize(buffer,
        getTargetSize: (w, h) => ui.TargetImageSize(width: decodeWidth > w ? w : decodeWidth));
      final frame = await codec.getNextFrame();
      final size = (frame.image.width, frame.image.height);
      frame.image.dispose();
      codec.dispose();
      return size;
    }
    Future<Uint8List> png(int w, int h) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Paint()..color = const ui.Color(0xFF336699));
      final image = await recorder.endRecording().toImage(w, h);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    }
    for (final (w, h, decodeWidth) in [(690, 3001, 1008), (1200, 3333, 1008),
        (1100, 2999, 1008), (800, 1203, 480), (1008, 1777, 1008)]) {
      final bytes = await png(w, h);
      expect(encodedImageSize(bytes), (w, h));
      expect(readerDecodedSize(w, h, decodeWidth), await decoded(bytes, decodeWidth),
        reason: '${w}x$h at $decodeWidth');
    }
  });
}
