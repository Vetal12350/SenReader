import 'dart:typed_data';

/// Pixel size from an encoded image header, without decoding (JPEG, PNG,
/// GIF, WebP). Returns null for unknown or truncated data. Used to give
/// reader pages their final height before they are decoded or shown.
(int, int)? encodedImageSize(Uint8List b) {
  int u16be(int o) => (b[o] << 8) | b[o + 1];
  int u16le(int o) => b[o] | (b[o + 1] << 8);
  int u24le(int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);
  int u32be(int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  (int, int)? valid(int w, int h) => w > 0 && h > 0 ? (w, h) : null;

  // PNG: signature, then IHDR width/height.
  if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return valid(u32be(16), u32be(20));
  }
  // GIF87a/89a: logical screen size.
  if (b.length >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return valid(u16le(6), u16le(8));
  }
  // WebP: RIFF....WEBP + VP8 / VP8L / VP8X chunk.
  if (b.length >= 30 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    final chunk = String.fromCharCodes(b.sublist(12, 16));
    if (chunk == 'VP8X') return valid(u24le(24) + 1, u24le(27) + 1);
    if (chunk == 'VP8L' && b[20] == 0x2F) {
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return valid((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    }
    if (chunk == 'VP8 ' && b[23] == 0x9D && b[24] == 0x01 && b[25] == 0x2A) {
      return valid(u16le(26) & 0x3FFF, u16le(28) & 0x3FFF);
    }
    return null;
  }
  // JPEG: walk marker segments to the first SOFn frame header.
  if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var o = 2;
    while (o + 9 < b.length) {
      if (b[o] != 0xFF) { o++; continue; }
      final marker = b[o + 1];
      if (marker == 0xFF) { o++; continue; } // fill byte
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        o += 2;
        continue;
      }
      final isSof = marker >= 0xC0 && marker <= 0xCF &&
          marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
      if (isSof) return valid(u16be(o + 7), u16be(o + 5));
      if (marker == 0xD9 || marker == 0xDA) return null; // EOI/SOS before SOF
      o += 2 + u16be(o + 2);
    }
  }
  return null;
}

/// Size the reader's decoder will produce for [width]×[height] with
/// `ResizeImage.resizeIfNeeded(decodeWidth, null, …)` (policy exact, no
/// upscaling): mirrors Flutter's integer arithmetic exactly, so the height
/// known in advance equals the decoded one and needs no later relayout.
(int, int) readerDecodedSize(int width, int height, int decodeWidth) {
  final targetWidth = decodeWidth < width ? decodeWidth : width;
  return (targetWidth, targetWidth ~/ (width / height));
}
