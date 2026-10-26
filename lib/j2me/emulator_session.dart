import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'gfx/font_atlas.dart';
import 'gfx/surface.dart';
import 'jar_loader.dart';
import 'key_codes.dart';
import 'vm/midp.dart';
import 'vm/natives.dart';
import 'vm/vm.dart';

/// Une partie en cours : un MIDlet lancé depuis un JAR.
///
/// La session crée la machine virtuelle, lance le MIDlet puis la fait avancer
/// à ~60 images par seconde. Les images dessinées par le jeu arrivent dans [frame].
class EmulatorSession {
  EmulatorSession(this.package, this.midlet);

  static const int width = Midp.width;
  static const int height = Midp.height;

  final JarPackage package;
  final MidletInfo midlet;

  /// Dernière image rendue par le jeu (null tant que le jeu n'a rien dessiné).
  final ValueNotifier<ui.Image?> frame = ValueNotifier(null);

  /// Journal affiché dans la console de démarrage.
  final ValueNotifier<List<String>> log = ValueNotifier(const []);

  Vm? vm;
  Midp? midp;
  Timer? _timer;
  bool _disposed = false;
  bool _decoding = false;
  Uint8List? _queued;
  final Set<J2meKey> _held = {};

  void _log(String line) {
    if (_disposed) return;
    final next = [...log.value, line];
    log.value = next.length > 80 ? next.sublist(next.length - 80) : next;
  }

  Future<void> boot() async {
    _log('Préparation des polices...');
    final atlas = await FontAtlas.build();
    if (_disposed) return;

    final machine = Vm(package, _log);
    registerNatives(machine);
    midp = registerMidp(machine, atlas, _present);
    machine.onExit = () => _log('Le jeu a demandé à quitter.');
    vm = machine;
    try {
      machine.startMidlet(midlet.className);
    } on JavaThrow catch (e) {
      _log('Démarrage impossible : ${e.cls} ${e.msg ?? ''}');
      return;
    }
    _timer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => machine.tick(),
    );
  }

  /// Convertit la surface ARGB du jeu en image Flutter (RGBA).
  void _present(Surface s) {
    if (_disposed) return;
    final rgba = Uint8List(s.w * s.h * 4);
    final out = rgba.buffer.asUint32List();
    final px = s.px;
    for (var i = 0; i < px.length; i++) {
      final v = px[i];
      out[i] = (v & 0xFF00FF00) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF);
    }
    if (_decoding) {
      _queued = rgba;
      return;
    }
    _decode(rgba, s.w, s.h);
  }

  void _decode(Uint8List rgba, int w, int h) {
    _decoding = true;
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, (img) {
      if (_disposed) {
        img.dispose();
        return;
      }
      final old = frame.value;
      frame.value = img;
      if (old != null) {
        Future.delayed(const Duration(milliseconds: 200), old.dispose);
      }
      _decoding = false;
      final q = _queued;
      if (q != null) {
        _queued = null;
        _decode(q, w, h);
      }
    });
  }

  /// Appelé par l'interface à chaque appui ou relâchement.
  void key(J2meKey k, bool down) {
    if (down) {
      if (!_held.add(k)) return;
    } else {
      if (!_held.remove(k)) return;
    }
    midp?.key(k.keyCode, down);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    frame.value?.dispose();
    frame.dispose();
    log.dispose();
  }
}
