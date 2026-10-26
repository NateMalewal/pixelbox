import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show TextPainter, TextSpan, TextStyle;

class Glyph {
  const Glyph(this.advance, this.offX, this.w, this.h, this.alpha);

  final int advance;
  final int offX;
  final int w;
  final int h;
  final Uint8List alpha;
}

class FontFace {
  FontFace(this.height, this.baseline, this._glyphs);

  final int height;
  final int baseline;
  final Map<int, Glyph> _glyphs;

  Glyph? glyph(int c) => _glyphs[c] ?? _glyphs[63];

  int charWidth(int c) => glyph(c)?.advance ?? height ~/ 2;

  int stringWidth(String s) {
    var w = 0;
    for (final u in s.codeUnits) {
      w += charWidth(u);
    }
    return w;
  }
}

/// Toutes les polices PixelBox (3 tailles, normal et gras), rasterisées au démarrage
/// avec le moteur de texte de Flutter puis dessinées pixel par pixel ensuite.
class FontAtlas {
  FontAtlas._(this._faces);

  final Map<int, FontFace> _faces;

  static int _key(int size, int style) => ((size & 0xFF) << 1) | (style & 1);

  /// [size] : 0 moyen, 8 petit, 16 grand. [style] : bit 0 = gras.
  FontFace face(int size, int style) =>
      _faces[_key(size, style)] ?? _faces[_key(0, 0)]!;

  static Future<FontAtlas> build() async {
    const sizes = {0: 12.0, 8: 10.0, 16: 15.0};
    final faces = <int, FontFace>{};
    for (final e in sizes.entries) {
      for (final bold in const [false, true]) {
        faces[_key(e.key, bold ? 1 : 0)] = await _buildFace(e.value, bold);
      }
    }
    return FontAtlas._(faces);
  }

  static Future<FontFace> _buildFace(double px, bool bold) async {
    final style = TextStyle(
      fontSize: px,
      fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
      color: const ui.Color(0xFFFFFFFF),
    );

    final painters = <int, TextPainter>{};
    final adv = <int, int>{};
    var total = 0;
    var lineH = 1;
    var base = 1;
    for (var c = 32; c < 256; c++) {
      final tp = TextPainter(
        text: TextSpan(text: String.fromCharCode(c), style: style),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      painters[c] = tp;
      final a = math.max(1, tp.width.round());
      adv[c] = a;
      total += a + 2;
      lineH = math.max(lineH, tp.height.ceil());
      if (c == 72) {
        base = tp
            .computeDistanceToActualBaseline(ui.TextBaseline.alphabetic)
            .round();
      }
    }

    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    final starts = <int, int>{};
    var x = 0;
    for (var c = 32; c < 256; c++) {
      starts[c] = x;
      painters[c]!.paint(canvas, ui.Offset(x + 1.0, 0));
      x += adv[c]! + 2;
    }
    final image = await rec.endRecording().toImage(total, lineH);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final data = bytes!.buffer.asUint8List();

    final glyphs = <int, Glyph>{};
    for (var c = 32; c < 256; c++) {
      final cellW = adv[c]! + 2;
      final alpha = Uint8List(cellW * lineH);
      for (var j = 0; j < lineH; j++) {
        for (var i = 0; i < cellW; i++) {
          alpha[j * cellW + i] = data[(j * total + starts[c]! + i) * 4 + 3];
        }
      }
      glyphs[c] = Glyph(adv[c]!, -1, cellW, lineH, alpha);
    }
    return FontFace(lineH, base, glyphs);
  }
}
