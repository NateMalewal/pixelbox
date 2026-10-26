import 'dart:math' as math;
import 'dart:typed_data';

import 'font_atlas.dart';

/// Image en mémoire : pixels ARGB 32 bits (0xAARRGGBB).
class Surface {
  Surface(this.w, this.h, {int fill = 0x00000000})
      : px = Uint32List(w * h)..fillRange(0, w * h, fill);

  final int w;
  final int h;
  final Uint32List px;

  Surface copy() {
    final s = Surface(w, h);
    s.px.setAll(0, px);
    return s;
  }
}

/// Mélange alpha d'un pixel source sur un pixel destination.
int blendPx(int dst, int src) {
  final a = src >>> 24;
  if (a == 255) return src;
  if (a == 0) return dst;
  final ia = 255 - a;
  final r = (((src >> 16) & 255) * a + ((dst >> 16) & 255) * ia) ~/ 255;
  final g = (((src >> 8) & 255) * a + ((dst >> 8) & 255) * ia) ~/ 255;
  final b = ((src & 255) * a + (dst & 255) * ia) ~/ 255;
  final da = dst >>> 24;
  final oa = a + (da * ia) ~/ 255;
  return (oa << 24) | (r << 16) | (g << 8) | b;
}

/// Équivalent de javax.microedition.lcdui.Graphics (état de dessin + primitives).
class Gfx {
  Gfx(this.s, this.atlas) : font = atlas.face(0, 0) {
    reset();
  }

  final Surface s;
  final FontAtlas atlas;

  int color = 0xFF000000;
  int tx = 0;
  int ty = 0;

  /// Rectangle de clip en coordonnées de la surface : [cx, cx2) x [cy, cy2).
  int cx = 0;
  int cy = 0;
  int cx2 = 0;
  int cy2 = 0;
  FontFace font;
  int fontSize = 0;
  int fontStyle = 0;

  void reset() {
    color = 0xFF000000;
    tx = 0;
    ty = 0;
    cx = 0;
    cy = 0;
    cx2 = s.w;
    cy2 = s.h;
  }

  // ----------------------------------------------------------------- clip

  void setClip(int x, int y, int w, int h) {
    cx = math.max(0, x + tx);
    cy = math.max(0, y + ty);
    cx2 = math.min(s.w, x + tx + math.max(0, w));
    cy2 = math.min(s.h, y + ty + math.max(0, h));
    if (cx2 < cx) cx2 = cx;
    if (cy2 < cy) cy2 = cy;
  }

  void clipRect(int x, int y, int w, int h) {
    cx = math.max(cx, x + tx);
    cy = math.max(cy, y + ty);
    cx2 = math.min(cx2, x + tx + math.max(0, w));
    cy2 = math.min(cy2, y + ty + math.max(0, h));
    if (cx2 < cx) cx2 = cx;
    if (cy2 < cy) cy2 = cy;
  }

  // ----------------------------------------------------------- primitives

  void _put(int x, int y, int c) {
    if (x >= cx && x < cx2 && y >= cy && y < cy2) {
      s.px[y * s.w + x] = c;
    }
  }

  /// Remplit un rectangle en coordonnées surface.
  void _fillDev(int x0, int y0, int x1, int y1) {
    x0 = math.max(x0, cx);
    y0 = math.max(y0, cy);
    x1 = math.min(x1, cx2);
    y1 = math.min(y1, cy2);
    if (x0 >= x1) return;
    for (var y = y0; y < y1; y++) {
      s.px.fillRange(y * s.w + x0, y * s.w + x1, color);
    }
  }

  void fillRect(int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return;
    _fillDev(x + tx, y + ty, x + tx + w, y + ty + h);
  }

  void drawRect(int x, int y, int w, int h) {
    if (w < 0 || h < 0) return;
    final x0 = x + tx;
    final y0 = y + ty;
    _fillDev(x0, y0, x0 + w + 1, y0 + 1);
    _fillDev(x0, y0 + h, x0 + w + 1, y0 + h + 1);
    _fillDev(x0, y0, x0 + 1, y0 + h + 1);
    _fillDev(x0 + w, y0, x0 + w + 1, y0 + h + 1);
  }

  void drawLine(int x1, int y1, int x2, int y2) {
    var x = x1 + tx;
    var y = y1 + ty;
    final ex = x2 + tx;
    final ey = y2 + ty;
    final dx = (ex - x).abs();
    final dy = -(ey - y).abs();
    final sx = x < ex ? 1 : -1;
    final sy = y < ey ? 1 : -1;
    var err = dx + dy;
    while (true) {
      _put(x, y, color);
      if (x == ex && y == ey) break;
      final e2 = 2 * err;
      if (e2 >= dy) {
        err += dy;
        x += sx;
      }
      if (e2 <= dx) {
        err += dx;
        y += sy;
      }
    }
  }

  void fillTriangle(int x1, int y1, int x2, int y2, int x3, int y3) {
    final ax = x1 + tx, ay = y1 + ty, bx = x2 + tx, by = y2 + ty, cxx = x3 + tx, cyy = y3 + ty;
    final minX = math.max(cx, math.min(ax, math.min(bx, cxx)));
    final maxX = math.min(cx2 - 1, math.max(ax, math.max(bx, cxx)));
    final minY = math.max(cy, math.min(ay, math.min(by, cyy)));
    final maxY = math.min(cy2 - 1, math.max(ay, math.max(by, cyy)));
    int edge(int px, int py, int qx, int qy, int x, int y) =>
        (qx - px) * (y - py) - (qy - py) * (x - px);
    final area = edge(ax, ay, bx, by, cxx, cyy);
    if (area == 0) return;
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final w0 = edge(bx, by, cxx, cyy, x, y);
        final w1 = edge(cxx, cyy, ax, ay, x, y);
        final w2 = edge(ax, ay, bx, by, x, y);
        final inside = area > 0
            ? (w0 >= 0 && w1 >= 0 && w2 >= 0)
            : (w0 <= 0 && w1 <= 0 && w2 <= 0);
        if (inside) s.px[y * s.w + x] = color;
      }
    }
  }

  bool _inArc(double dx, double dy, int start, int arc) {
    if (arc >= 360 || arc <= -360) return true;
    var ang = math.atan2(-dy, dx) * 180 / math.pi;
    if (ang < 0) ang += 360;
    double rel = arc >= 0 ? ang - start : start - ang;
    rel %= 360;
    if (rel < 0) rel += 360;
    return rel <= arc.abs();
  }

  void fillArc(int x, int y, int w, int h, int start, int arc) {
    if (w <= 0 || h <= 0) return;
    final x0 = x + tx;
    final y0 = y + ty;
    final rx = w / 2;
    final ry = h / 2;
    for (var yy = math.max(y0, cy); yy < math.min(y0 + h, cy2); yy++) {
      for (var xx = math.max(x0, cx); xx < math.min(x0 + w, cx2); xx++) {
        final dx = (xx + 0.5 - x0 - rx) / rx;
        final dy = (yy + 0.5 - y0 - ry) / ry;
        if (dx * dx + dy * dy <= 1 && _inArc(dx, dy, start, arc)) {
          s.px[yy * s.w + xx] = color;
        }
      }
    }
  }

  void drawArc(int x, int y, int w, int h, int start, int arc) {
    if (w <= 0 || h <= 0) return;
    final x0 = x + tx;
    final y0 = y + ty;
    final rx = w / 2;
    final ry = h / 2;
    final inner = math.max(0.0, 1 - 1.3 / math.min(rx, ry));
    for (var yy = math.max(y0, cy); yy < math.min(y0 + h + 1, cy2); yy++) {
      for (var xx = math.max(x0, cx); xx < math.min(x0 + w + 1, cx2); xx++) {
        final dx = (xx + 0.5 - x0 - rx) / rx;
        final dy = (yy + 0.5 - y0 - ry) / ry;
        final d2 = dx * dx + dy * dy;
        if (d2 <= 1 && d2 >= inner * inner && _inArc(dx, dy, start, arc)) {
          s.px[yy * s.w + xx] = color;
        }
      }
    }
  }

  // ---------------------------------------------------------------- texte

  /// Retourne la position (x, y) du coin haut-gauche selon l'ancre MIDP.
  (int, int) _anchorText(String str, int x, int y, int anchor) {
    final w = font.stringWidth(str);
    var px = x;
    if ((anchor & 1) != 0) {
      px = x - w ~/ 2;
    } else if ((anchor & 8) != 0) {
      px = x - w;
    }
    var py = y;
    if ((anchor & 32) != 0) {
      py = y - font.height;
    } else if ((anchor & 64) != 0) {
      py = y - font.baseline;
    }
    return (px, py);
  }

  void drawString(String str, int x, int y, int anchor) {
    final (px, py) = _anchorText(str, x, y, anchor);
    var pen = px + tx;
    final top = py + ty;
    final rgb = color & 0x00FFFFFF;
    for (final u in str.codeUnits) {
      final g = font.glyph(u);
      if (g != null) {
        final gx = pen + g.offX;
        for (var j = 0; j < g.h; j++) {
          final yy = top + j;
          if (yy < cy || yy >= cy2) continue;
          for (var i = 0; i < g.w; i++) {
            final a = g.alpha[j * g.w + i];
            if (a == 0) continue;
            final xx = gx + i;
            if (xx < cx || xx >= cx2) continue;
            final idx = yy * s.w + xx;
            s.px[idx] = blendPx(s.px[idx], (a << 24) | rgb);
          }
        }
        pen += g.advance;
      }
    }
  }

  // --------------------------------------------------------------- images

  /// Copie une région de [src] avec une des 8 transformations MIDP.
  /// Les coordonnées de destination sont celles du coin haut-gauche (avant translate).
  void blit(Surface src, int sx, int sy, int sw, int sh, int dx, int dy, int tr) {
    // Région source bornée à l'image.
    if (sx < 0) {
      sw += sx;
      sx = 0;
    }
    if (sy < 0) {
      sh += sy;
      sy = 0;
    }
    sw = math.min(sw, src.w - sx);
    sh = math.min(sh, src.h - sy);
    if (sw <= 0 || sh <= 0) return;

    final swap = tr == 4 || tr == 5 || tr == 6 || tr == 7;
    final dw = swap ? sh : sw;
    final dh = swap ? sw : sh;
    final ox = dx + tx;
    final oy = dy + ty;

    final v0 = math.max(0, cy - oy);
    final v1 = math.min(dh, cy2 - oy);
    final u0 = math.max(0, cx - ox);
    final u1 = math.min(dw, cx2 - ox);

    for (var v = v0; v < v1; v++) {
      final row = (oy + v) * s.w + ox;
      for (var u = u0; u < u1; u++) {
        int x;
        int y;
        switch (tr) {
          case 0:
            x = u;
            y = v;
          case 1:
            x = u;
            y = sh - 1 - v;
          case 2:
            x = sw - 1 - u;
            y = v;
          case 3:
            x = sw - 1 - u;
            y = sh - 1 - v;
          case 4:
            x = v;
            y = u;
          case 5:
            x = v;
            y = sh - 1 - u;
          case 6:
            x = sw - 1 - v;
            y = u;
          default:
            x = sw - 1 - v;
            y = sh - 1 - u;
        }
        final c = src.px[(sy + y) * src.w + sx + x];
        final a = c >>> 24;
        if (a == 0) continue;
        final di = row + u;
        s.px[di] = a == 255 ? c : blendPx(s.px[di], c);
      }
    }
  }

  /// Applique l'ancre MIDP à une image de taille (w, h).
  (int, int) anchorImage(int x, int y, int w, int h, int anchor) {
    var px = x;
    if ((anchor & 1) != 0) {
      px = x - w ~/ 2;
    } else if ((anchor & 8) != 0) {
      px = x - w;
    }
    var py = y;
    if ((anchor & 2) != 0) {
      py = y - h ~/ 2;
    } else if ((anchor & 32) != 0) {
      py = y - h;
    }
    return (px, py);
  }

  void drawRgb(List<dynamic> rgb, int off, int scan, int x, int y, int w, int h, bool alpha) {
    for (var j = 0; j < h; j++) {
      final yy = y + ty + j;
      if (yy < cy || yy >= cy2) continue;
      for (var i = 0; i < w; i++) {
        final xx = x + tx + i;
        if (xx < cx || xx >= cx2) continue;
        var c = (rgb[off + j * scan + i] as int) & 0xFFFFFFFF;
        if (!alpha) c |= 0xFF000000;
        final idx = yy * s.w + xx;
        s.px[idx] = blendPx(s.px[idx], c);
      }
    }
  }
}
