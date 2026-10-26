import 'dart:collection';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../gfx/font_atlas.dart';
import '../gfx/surface.dart';
import '../key_codes.dart';
import 'vm.dart';

const _lcdui = 'javax/microedition/lcdui/';
const _game = 'javax/microedition/lcdui/game/';

class _UiEvent {
  _UiEvent(this.method, this.args, [this.onDone]);

  final JMethod method;
  final List<Object?> args;
  final void Function()? onDone;
}

/// État attaché à un objet Canvas / GameCanvas.
class CanvasState {
  Surface? buffer;
  JObject? listener;
  final List<JObject> commands = [];
}

/// Le « téléphone » : écran, file d'événements d'interface, clavier.
class Midp {
  Midp(this.vm, this.atlas, this.onPresent)
      : screen = Surface(width, height, fill: 0xFF000000);

  static const int width = 240;
  static const int height = 320;

  final Vm vm;
  final FontAtlas atlas;
  final void Function(Surface) onPresent;
  final Surface screen;

  JObject? displayObj;
  JObject? current;
  bool repaintPending = false;

  /// Touches maintenues / appuyées depuis le dernier getKeyStates().
  int held = 0;
  int latched = 0;

  final Queue<_UiEvent> _queue = Queue();
  JThread? _ui;
  _UiEvent? _cur;

  CanvasState state(JObject o) => (o.native ??= CanvasState()) as CanvasState;

  void post(JObject target, String name, String desc, List<Object?> args) {
    final m = vm.findMethod(target.cls, name, desc);
    if (m == null || m.native != null) return;
    _queue.add(_UiEvent(m, [target, ...args]));
  }

  void key(int keyCode, bool down) {
    final act = GameAction.fromKeyCode(keyCode);
    if (act != 0) {
      final bit = 1 << act;
      if (down) {
        held |= bit;
        latched |= bit;
      } else {
        held &= ~bit;
      }
    }
    final c = current;
    if (c != null) {
      post(c, down ? 'keyPressed' : 'keyReleased', '(I)V', [keyCode]);
    }
  }

  /// Appelée à chaque tick de la VM, avant l'exécution des threads.
  void tick() {
    final t = _ui;
    if (t != null) {
      if (!t.done) return;
      _ui = null;
      final done = _cur?.onDone;
      _cur = null;
      done?.call();
    }
    if (_queue.isNotEmpty) {
      final e = _queue.removeFirst();
      _cur = e;
      _ui = vm.spawn('ui', e.method, e.args);
      return;
    }
    if (repaintPending && current != null) {
      repaintPending = false;
      _startPaint(current!);
    }
  }

  void _startPaint(JObject canvas) {
    final m = vm.findMethod(canvas.cls, 'paint', '(L${_lcdui}Graphics;)V');
    if (m == null || m.native != null) {
      final buf = state(canvas).buffer;
      if (buf != null) onPresent(buf);
      return;
    }
    final g = JObject(vm.classes['${_lcdui}Graphics']!)
      ..native = Gfx(screen, atlas);
    final e = _UiEvent(m, [canvas, g], () => onPresent(screen));
    _cur = e;
    _ui = vm.spawn('ui', e.method, e.args);
  }
}

// ------------------------------------------------------------------------

Surface? _decodeImage(Uint8List bytes) {
  final im = img.decodeImage(bytes);
  if (im == null) return null;
  final s = Surface(im.width, im.height);
  final alpha = im.hasAlpha;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final p = im.getPixel(x, y);
      final r = (p.rNormalized * 255).round();
      final g = (p.gNormalized * 255).round();
      final b = (p.bNormalized * 255).round();
      final a = alpha ? (p.aNormalized * 255).round() : 255;
      s.px[y * im.width + x] = (a << 24) | (r << 16) | (g << 8) | b;
    }
  }
  return s;
}

Midp registerMidp(Vm vm, FontAtlas atlas, void Function(Surface) onPresent) {
  final midp = Midp(vm, atlas, onPresent);
  final n = vm.natives;

  // ----------------------------------------------------------- classes
  vm.defineClass('${_lcdui}Displayable', 'java/lang/Object');
  vm.defineClass('${_lcdui}Canvas', '${_lcdui}Displayable');
  vm.defineClass('${_game}GameCanvas', '${_lcdui}Canvas');
  for (final c in const ['Display', 'Graphics', 'Image', 'Font', 'Command']) {
    vm.defineClass('$_lcdui$c', 'java/lang/Object');
  }
  vm.defineClass('${_lcdui}CommandListener', 'java/lang/Object', iface: true);

  final gfxClass = vm.classes['${_lcdui}Graphics']!;
  final imageClass = vm.classes['${_lcdui}Image']!;
  final fontClass = vm.classes['${_lcdui}Font']!;

  // Constantes.
  final canvasSt = vm.classes['${_lcdui}Canvas']!.statics;
  const keys = {
    'UP': 1,
    'LEFT': 2,
    'RIGHT': 5,
    'DOWN': 6,
    'FIRE': 8,
    'GAME_A': 9,
    'GAME_B': 10,
    'GAME_C': 11,
    'GAME_D': 12,
    'KEY_NUM0': 48,
    'KEY_NUM1': 49,
    'KEY_NUM2': 50,
    'KEY_NUM3': 51,
    'KEY_NUM4': 52,
    'KEY_NUM5': 53,
    'KEY_NUM6': 54,
    'KEY_NUM7': 55,
    'KEY_NUM8': 56,
    'KEY_NUM9': 57,
    'KEY_STAR': 42,
    'KEY_POUND': 35,
  };
  canvasSt.addAll(keys);
  vm.classes['${_game}GameCanvas']!.statics.addAll(const {
    'UP_PRESSED': 1 << 1,
    'LEFT_PRESSED': 1 << 2,
    'RIGHT_PRESSED': 1 << 5,
    'DOWN_PRESSED': 1 << 6,
    'FIRE_PRESSED': 1 << 8,
    'GAME_A_PRESSED': 1 << 9,
    'GAME_B_PRESSED': 1 << 10,
    'GAME_C_PRESSED': 1 << 11,
    'GAME_D_PRESSED': 1 << 12,
  });
  gfxClass.statics.addAll(const {
    'HCENTER': 1,
    'VCENTER': 2,
    'LEFT': 4,
    'RIGHT': 8,
    'TOP': 16,
    'BOTTOM': 32,
    'BASELINE': 64,
    'SOLID': 0,
    'DOTTED': 1,
  });
  fontClass.statics.addAll(const {
    'FACE_SYSTEM': 0,
    'FACE_MONOSPACE': 32,
    'FACE_PROPORTIONAL': 64,
    'STYLE_PLAIN': 0,
    'STYLE_BOLD': 1,
    'STYLE_ITALIC': 2,
    'STYLE_UNDERLINED': 4,
    'SIZE_MEDIUM': 0,
    'SIZE_SMALL': 8,
    'SIZE_LARGE': 16,
  });
  vm.classes['${_lcdui}Command']!.statics.addAll(const {
    'SCREEN': 1,
    'BACK': 2,
    'CANCEL': 3,
    'OK': 4,
    'HELP': 5,
    'STOP': 6,
    'EXIT': 7,
    'ITEM': 8,
  });

  // --------------------------------------------------------- Displayable
  const dsp = '${_lcdui}Displayable';
  n['$dsp.<init>()V'] = (vm, t, a) => null;
  n['$dsp.getWidth()I'] = (vm, t, a) => Midp.width;
  n['$dsp.getHeight()I'] = (vm, t, a) => Midp.height;
  n['$dsp.isShown()Z'] = (vm, t, a) => identical(midp.current, a[0]) ? 1 : 0;
  n['$dsp.setTitle(Ljava/lang/String;)V'] = (vm, t, a) => null;
  n['$dsp.setCommandListener(L${_lcdui}CommandListener;)V'] = (vm, t, a) {
    midp.state(a[0] as JObject).listener = a[1] as JObject?;
    return null;
  };
  n['$dsp.addCommand(L${_lcdui}Command;)V'] = (vm, t, a) {
    midp.state(a[0] as JObject).commands.add(a[1] as JObject);
    return null;
  };
  n['$dsp.removeCommand(L${_lcdui}Command;)V'] = (vm, t, a) {
    midp.state(a[0] as JObject).commands.remove(a[1]);
    return null;
  };

  // -------------------------------------------------------------- Canvas
  const cv = '${_lcdui}Canvas';
  n['$cv.<init>()V'] = (vm, t, a) => null;
  n['$cv.repaint()V'] = (vm, t, a) {
    midp.repaintPending = true;
    return null;
  };
  n['$cv.repaint(IIII)V'] = n['$cv.repaint()V']!;
  n['$cv.serviceRepaints()V'] = (vm, t, a) {
    t.yielding = true;
    return null;
  };
  n['$cv.setFullScreenMode(Z)V'] = (vm, t, a) => null;
  n['$cv.isDoubleBuffered()Z'] = (vm, t, a) => 1;
  n['$cv.hasPointerEvents()Z'] = (vm, t, a) => 0;
  n['$cv.hasPointerMotionEvents()Z'] = (vm, t, a) => 0;
  n['$cv.hasRepeatEvents()Z'] = (vm, t, a) => 0;
  n['$cv.getGameAction(I)I'] =
      (vm, t, a) => GameAction.fromKeyCode(a[1] as int);
  n['$cv.getKeyCode(I)I'] = (vm, t, a) {
    switch (a[1]) {
      case GameAction.up:
        return -1;
      case GameAction.down:
        return -2;
      case GameAction.left:
        return -3;
      case GameAction.right:
        return -4;
      case GameAction.fire:
        return -5;
      case GameAction.gameA:
        return 49;
      case GameAction.gameB:
        return 51;
      case GameAction.gameC:
        return 55;
      case GameAction.gameD:
        return 57;
      default:
        return 0;
    }
  };
  n['$cv.getKeyName(I)Ljava/lang/String;'] = (vm, t, a) => vm.intern('${a[1]}');
  for (final name in const ['keyPressed', 'keyReleased', 'keyRepeated']) {
    n['$cv.$name(I)V'] = (vm, t, a) => null;
  }
  for (final name in const [
    'pointerPressed',
    'pointerReleased',
    'pointerDragged'
  ]) {
    n['$cv.$name(II)V'] = (vm, t, a) => null;
  }
  n['$cv.showNotify()V'] = (vm, t, a) => null;
  n['$cv.hideNotify()V'] = (vm, t, a) => null;
  n['$cv.sizeChanged(II)V'] = (vm, t, a) => null;

  // ---------------------------------------------------------- GameCanvas
  const gc = '${_game}GameCanvas';
  n['$gc.<init>(Z)V'] = (vm, t, a) => null;
  Surface buffer(JObject canvas) {
    final st = midp.state(canvas);
    return st.buffer ??= Surface(Midp.width, Midp.height, fill: 0xFFFFFFFF);
  }

  n['$gc.getGraphics()L${_lcdui}Graphics;'] = (vm, t, a) =>
      JObject(gfxClass)..native = Gfx(buffer(a[0] as JObject), atlas);
  n['$gc.flushGraphics()V'] = (vm, t, a) {
    onPresent(buffer(a[0] as JObject));
    return null;
  };
  n['$gc.flushGraphics(IIII)V'] = n['$gc.flushGraphics()V']!;
  n['$gc.getKeyStates()I'] = (vm, t, a) {
    final r = midp.held | midp.latched;
    midp.latched = 0;
    return r;
  };
  n['$gc.paint(L${_lcdui}Graphics;)V'] = (vm, t, a) {
    final g = (a[1] as JObject).native as Gfx;
    g.blit(buffer(a[0] as JObject), 0, 0, Midp.width, Midp.height, 0, 0, 0);
    return null;
  };

  // ------------------------------------------------------------- Display
  const dp = '${_lcdui}Display';
  final displayClass = vm.classes[dp]!;
  n['$dp.getDisplay(Ljavax/microedition/midlet/MIDlet;)L$dp;'] =
      (vm, t, a) => midp.displayObj ??= JObject(displayClass);
  n['$dp.setCurrent(L${_lcdui}Displayable;)V'] = (vm, t, a) {
    final d = a[1] as JObject?;
    if (d == null) return null;
    if (!d.cls.isSubclassOf('${_lcdui}Canvas')) {
      vm.log(
          'Écran non géré : ${d.cls.name} (seul Canvas existe pour l\'instant)');
      return null;
    }
    midp.current = d;
    midp.repaintPending = true;
    midp.post(d, 'showNotify', '()V', const []);
    return null;
  };
  n['$dp.getCurrent()L${_lcdui}Displayable;'] = (vm, t, a) => midp.current;
  n['$dp.callSerially(Ljava/lang/Runnable;)V'] = (vm, t, a) {
    final r = a[1] as JObject?;
    if (r != null) midp.post(r, 'run', '()V', const []);
    return null;
  };
  n['$dp.isColor()Z'] = (vm, t, a) => 1;
  n['$dp.numColors()I'] = (vm, t, a) => 16777216;
  n['$dp.numAlphaLevels()I'] = (vm, t, a) => 256;
  n['$dp.vibrate(I)Z'] = (vm, t, a) => 1;
  n['$dp.flashBacklight(I)Z'] = (vm, t, a) => 1;

  // --------------------------------------------------------------- Image
  const im = '${_lcdui}Image';
  JObject makeImage(Surface s, {bool mutable = false}) {
    final o = JObject(imageClass)..native = s;
    o.fields['_mutable'] = mutable ? 1 : 0;
    return o;
  }

  Surface surf(Object? o) {
    if (o == null) throw JavaThrow('java/lang/NullPointerException');
    return (o as JObject).native as Surface;
  }

  n['$im.createImage(Ljava/lang/String;)L$im;'] = (vm, t, a) {
    if (a[0] == null) throw JavaThrow('java/lang/NullPointerException');
    final name = a[0] as String;
    final key = name.startsWith('/') ? name.substring(1) : name;
    final bytes = vm.jar.files[key];
    if (bytes == null) throw JavaThrow('java/io/IOException', name);
    final s = _decodeImage(bytes);
    if (s == null) {
      throw JavaThrow('java/io/IOException', 'image illisible : $name');
    }
    return makeImage(s);
  };
  n['$im.createImage(II)L$im;'] = (vm, t, a) => makeImage(
      Surface(a[0] as int, a[1] as int, fill: 0xFFFFFFFF),
      mutable: true);
  n['$im.createImage([BII)L$im;'] = (vm, t, a) {
    final d = (a[0] as JArray).data as Int8List;
    final off = a[1] as int;
    final len = a[2] as int;
    final s = _decodeImage(Uint8List.sublistView(d, off, off + len));
    if (s == null) {
      throw JavaThrow('java/lang/IllegalArgumentException', 'image illisible');
    }
    return makeImage(s);
  };
  n['$im.createImage(L$im;)L$im;'] = (vm, t, a) => makeImage(surf(a[0]).copy());
  n['$im.createRGBImage([IIIZ)L$im;'] = (vm, t, a) {
    final data = (a[0] as JArray).data;
    final w = a[1] as int;
    final h = a[2] as int;
    final alpha = (a[3] as int) != 0;
    final s = Surface(w, h);
    for (var i = 0; i < w * h; i++) {
      var c = (data[i] as int) & 0xFFFFFFFF;
      if (!alpha) c |= 0xFF000000;
      s.px[i] = c;
    }
    return makeImage(s);
  };
  n['$im.getWidth()I'] = (vm, t, a) => surf(a[0]).w;
  n['$im.getHeight()I'] = (vm, t, a) => surf(a[0]).h;
  n['$im.isMutable()Z'] = (vm, t, a) => (a[0] as JObject).fields['_mutable'];
  n['$im.getGraphics()L${_lcdui}Graphics;'] =
      (vm, t, a) => JObject(gfxClass)..native = Gfx(surf(a[0]), atlas);
  n['$im.getRGB([IIIIIII)V'] = (vm, t, a) {
    final s = surf(a[0]);
    final out = (a[1] as JArray).data;
    final off = a[2] as int;
    final scan = a[3] as int;
    final x = a[4] as int;
    final y = a[5] as int;
    final w = a[6] as int;
    final h = a[7] as int;
    for (var j = 0; j < h; j++) {
      for (var i = 0; i < w; i++) {
        final sx = x + i;
        final sy = y + j;
        out[off + j * scan + i] = (sx >= 0 && sy >= 0 && sx < s.w && sy < s.h)
            ? s.px[sy * s.w + sx]
            : 0;
      }
    }
    return null;
  };

  // ----------------------------------------------------------------- Font
  const fn = '${_lcdui}Font';
  JObject makeFont(int face, int style, int size) {
    final o = JObject(fontClass)..native = atlas.face(size, style);
    o.fields['face'] = face;
    o.fields['style'] = style;
    o.fields['size'] = size;
    return o;
  }

  FontFace ff(Object? o) => (o as JObject).native as FontFace;
  n['$fn.getFont(III)L$fn;'] =
      (vm, t, a) => makeFont(a[0] as int, a[1] as int, a[2] as int);
  n['$fn.getDefaultFont()L$fn;'] = (vm, t, a) => makeFont(0, 0, 0);
  n['$fn.stringWidth(Ljava/lang/String;)I'] =
      (vm, t, a) => ff(a[0]).stringWidth(a[1] as String);
  n['$fn.charWidth(C)I'] = (vm, t, a) => ff(a[0]).charWidth(a[1] as int);
  n['$fn.substringWidth(Ljava/lang/String;II)I'] = (vm, t, a) {
    final s = a[1] as String;
    final o = a[2] as int;
    return ff(a[0]).stringWidth(s.substring(o, o + (a[3] as int)));
  };
  n['$fn.getHeight()I'] = (vm, t, a) => ff(a[0]).height;
  n['$fn.getBaselinePosition()I'] = (vm, t, a) => ff(a[0]).baseline;
  n['$fn.getStyle()I'] = (vm, t, a) => (a[0] as JObject).fields['style'];
  n['$fn.getSize()I'] = (vm, t, a) => (a[0] as JObject).fields['size'];
  n['$fn.getFace()I'] = (vm, t, a) => (a[0] as JObject).fields['face'];
  n['$fn.isBold()Z'] = (vm, t, a) =>
      (((a[0] as JObject).fields['style'] as int) & 1) != 0 ? 1 : 0;
  n['$fn.isPlain()Z'] =
      (vm, t, a) => (a[0] as JObject).fields['style'] == 0 ? 1 : 0;

  // -------------------------------------------------------------- Command
  const cm = '${_lcdui}Command';
  n['$cm.<init>(Ljava/lang/String;II)V'] = (vm, t, a) {
    final o = a[0] as JObject;
    o.fields['label'] = a[1];
    o.fields['type'] = a[2];
    o.fields['priority'] = a[3];
    return null;
  };
  n['$cm.<init>(Ljava/lang/String;Ljava/lang/String;II)V'] = (vm, t, a) {
    final o = a[0] as JObject;
    o.fields['label'] = a[1];
    o.fields['type'] = a[3];
    o.fields['priority'] = a[4];
    return null;
  };
  n['$cm.getLabel()Ljava/lang/String;'] =
      (vm, t, a) => (a[0] as JObject).fields['label'];
  n['$cm.getCommandType()I'] = (vm, t, a) => (a[0] as JObject).fields['type'];
  n['$cm.getPriority()I'] = (vm, t, a) => (a[0] as JObject).fields['priority'];

  // ------------------------------------------------------------- Graphics
  const gr = '${_lcdui}Graphics';
  Gfx g(List<Object?> a) => (a[0] as JObject).native as Gfx;
  int rgb(int r, int gg, int b) =>
      0xFF000000 | ((r & 255) << 16) | ((gg & 255) << 8) | (b & 255);

  n['$gr.setColor(I)V'] = (vm, t, a) {
    g(a).color = 0xFF000000 | ((a[1] as int) & 0xFFFFFF);
    return null;
  };
  n['$gr.setColor(III)V'] = (vm, t, a) {
    g(a).color = rgb(a[1] as int, a[2] as int, a[3] as int);
    return null;
  };
  n['$gr.setGrayScale(I)V'] = (vm, t, a) {
    final v = a[1] as int;
    g(a).color = rgb(v, v, v);
    return null;
  };
  n['$gr.getColor()I'] = (vm, t, a) => g(a).color & 0xFFFFFF;
  n['$gr.translate(II)V'] = (vm, t, a) {
    g(a).tx += a[1] as int;
    g(a).ty += a[2] as int;
    return null;
  };
  n['$gr.getTranslateX()I'] = (vm, t, a) => g(a).tx;
  n['$gr.getTranslateY()I'] = (vm, t, a) => g(a).ty;
  n['$gr.setClip(IIII)V'] = (vm, t, a) {
    g(a).setClip(a[1] as int, a[2] as int, a[3] as int, a[4] as int);
    return null;
  };
  n['$gr.clipRect(IIII)V'] = (vm, t, a) {
    g(a).clipRect(a[1] as int, a[2] as int, a[3] as int, a[4] as int);
    return null;
  };
  n['$gr.getClipX()I'] = (vm, t, a) => g(a).cx - g(a).tx;
  n['$gr.getClipY()I'] = (vm, t, a) => g(a).cy - g(a).ty;
  n['$gr.getClipWidth()I'] = (vm, t, a) => g(a).cx2 - g(a).cx;
  n['$gr.getClipHeight()I'] = (vm, t, a) => g(a).cy2 - g(a).cy;
  n['$gr.setFont(L$fn;)V'] = (vm, t, a) {
    if (a[1] != null) g(a).font = ff(a[1]);
    return null;
  };
  n['$gr.getFont()L$fn;'] = (vm, t, a) => makeFont(0, 0, 0);
  n['$gr.setStrokeStyle(I)V'] = (vm, t, a) => null;
  n['$gr.getStrokeStyle()I'] = (vm, t, a) => 0;

  n['$gr.fillRect(IIII)V'] = (vm, t, a) {
    g(a).fillRect(a[1] as int, a[2] as int, a[3] as int, a[4] as int);
    return null;
  };
  n['$gr.drawRect(IIII)V'] = (vm, t, a) {
    g(a).drawRect(a[1] as int, a[2] as int, a[3] as int, a[4] as int);
    return null;
  };
  n['$gr.fillRoundRect(IIIIII)V'] = (vm, t, a) {
    g(a).fillRect(a[1] as int, a[2] as int, a[3] as int, a[4] as int);
    return null;
  };
  n['$gr.drawRoundRect(IIIIII)V'] = (vm, t, a) {
    g(a).drawRect(a[1] as int, a[2] as int, a[3] as int, a[4] as int);
    return null;
  };
  n['$gr.drawLine(IIII)V'] = (vm, t, a) {
    g(a).drawLine(a[1] as int, a[2] as int, a[3] as int, a[4] as int);
    return null;
  };
  n['$gr.fillTriangle(IIIIII)V'] = (vm, t, a) {
    g(a).fillTriangle(a[1] as int, a[2] as int, a[3] as int, a[4] as int,
        a[5] as int, a[6] as int);
    return null;
  };
  n['$gr.fillArc(IIIIII)V'] = (vm, t, a) {
    g(a).fillArc(a[1] as int, a[2] as int, a[3] as int, a[4] as int,
        a[5] as int, a[6] as int);
    return null;
  };
  n['$gr.drawArc(IIIIII)V'] = (vm, t, a) {
    g(a).drawArc(a[1] as int, a[2] as int, a[3] as int, a[4] as int,
        a[5] as int, a[6] as int);
    return null;
  };

  n['$gr.drawString(Ljava/lang/String;III)V'] = (vm, t, a) {
    if (a[1] == null) throw JavaThrow('java/lang/NullPointerException');
    g(a).drawString(a[1] as String, a[2] as int, a[3] as int, a[4] as int);
    return null;
  };
  n['$gr.drawSubstring(Ljava/lang/String;IIIII)V'] = (vm, t, a) {
    final s = a[1] as String;
    final o = a[2] as int;
    g(a).drawString(s.substring(o, o + (a[3] as int)), a[4] as int, a[5] as int,
        a[6] as int);
    return null;
  };
  n['$gr.drawChar(CIII)V'] = (vm, t, a) {
    g(a).drawString(String.fromCharCode(a[1] as int), a[2] as int, a[3] as int,
        a[4] as int);
    return null;
  };
  n['$gr.drawChars([CIIIII)V'] = (vm, t, a) {
    final d = (a[1] as JArray).data.cast<int>();
    final o = a[2] as int;
    final s = String.fromCharCodes(d.sublist(o, o + (a[3] as int)));
    g(a).drawString(s, a[4] as int, a[5] as int, a[6] as int);
    return null;
  };

  n['$gr.drawImage(L$im;III)Z'] = (vm, t, a) {
    final s = surf(a[1]);
    final gg = g(a);
    final (x, y) =
        gg.anchorImage(a[2] as int, a[3] as int, s.w, s.h, a[4] as int);
    gg.blit(s, 0, 0, s.w, s.h, x, y, 0);
    return 1;
  };
  n['$gr.drawRegion(L$im;IIIIIIII)V'] = (vm, t, a) {
    final s = surf(a[1]);
    final gg = g(a);
    final w = a[4] as int;
    final h = a[5] as int;
    final tr = a[6] as int;
    final swap = tr >= 4;
    final (x, y) = gg.anchorImage(
        a[7] as int, a[8] as int, swap ? h : w, swap ? w : h, a[9] as int);
    gg.blit(s, a[2] as int, a[3] as int, w, h, x, y, tr);
    return null;
  };
  n['$gr.drawRGB([IIIIIIIZ)V'] = (vm, t, a) {
    g(a).drawRgb((a[1] as JArray).data, a[2] as int, a[3] as int, a[4] as int,
        a[5] as int, a[6] as int, a[7] as int, (a[8] as int) != 0);
    return null;
  };

  vm.preTick = midp.tick;
  return midp;
}
