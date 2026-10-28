import 'dart:async';
import 'dart:ui' as ui;
import 'vm/rms_storage.dart';
import 'package:flutter/foundation.dart';

import 'gfx/font_atlas.dart';
import 'gfx/surface.dart';
import 'jar_loader.dart';
import 'key_codes.dart';
import 'vm/midp.dart';
import 'vm/natives.dart';
import 'vm/java_library.dart';
import 'vm/rms.dart';
import 'vm/vm.dart';

enum GamePerformanceProfile { adaptive, balanced, performance, economy }

extension GamePerformanceProfileLabel on GamePerformanceProfile {
  String get label => switch (this) {
        GamePerformanceProfile.adaptive => 'Adaptatif',
        GamePerformanceProfile.balanced => 'Équilibré',
        GamePerformanceProfile.performance => 'Performance',
        GamePerformanceProfile.economy => 'Économie',
      };

  String get description => switch (this) {
        GamePerformanceProfile.adaptive =>
          'Ajuste le budget selon le temps VM et les images.',
        GamePerformanceProfile.balanced =>
          'Budget standard, adapté à la cadence choisie.',
        GamePerformanceProfile.performance =>
          'Jusqu’à 50 % de budget VM supplémentaire.',
        GamePerformanceProfile.economy =>
          'Réduit le budget pour limiter la charge.',
      };
}

class EmulatorDiagnostics {
  const EmulatorDiagnostics({
    this.renderFps = 0,
    this.averageVmMs = 0,
    this.averageConvertMs = 0,
    this.averageDecodeMs = 0,
    this.vmSaturated = false,
    this.renderBacklog = false,
    this.bytecodesPerSecond = 0,
    this.vmLocation = 'Démarrage',
    this.lastImageResource = '',
    this.lastImageDecodeMs = 0,
  });

  final double renderFps;
  final double averageVmMs;
  final double averageConvertMs;
  final double averageDecodeMs;
  final bool vmSaturated;
  final bool renderBacklog;
  final double bytecodesPerSecond;
  final String vmLocation;
  final String lastImageResource;
  final double lastImageDecodeMs;
}

/// Une partie en cours : un MIDlet lancé depuis un JAR.
class EmulatorSession {
  EmulatorSession(
    this.package,
    this.midlet, {
    this.audioVolume = 100,
    this.startLandscape = false,
    this.gameFps = 60,
    this.controlsOpacity = 0.88,
    this.hapticsEnabled = true,
    this.performanceProfile = GamePerformanceProfile.adaptive,
  });

  static const int width = Midp.width;
  static const int height = Midp.height;

  final JarPackage package;
  final MidletInfo midlet;
  final int audioVolume;
  final bool startLandscape;
  final int gameFps;
  final double controlsOpacity;
  final bool hapticsEnabled;
  final GamePerformanceProfile performanceProfile;

  final ValueNotifier<ui.Image?> frame = ValueNotifier(null);
  final ValueNotifier<List<String>> log = ValueNotifier(const []);
  final ValueNotifier<bool> exited = ValueNotifier(false);
  final ValueNotifier<EmulatorDiagnostics> diagnostics =
      ValueNotifier(const EmulatorDiagnostics());

  final RmsBackend rms = RmsBackend();
  final RmsStorage rmsStorage = RmsStorage();

  Vm? vm;
  Midp? midp;

  Timer? _timer;
  Timer? _diagnosticTimer;
  bool _disposed = false;
  bool _exitRequested = false;
  bool _decoding = false;
  Uint8List? _rgbaBuffer;

  // Surface la plus récente à afficher après le décodage en cours.
  Surface? _queuedSurface;
  final Set<String> _reportedLogs = {};
  int _decodedFrames = 0;
  int _vmSamples = 0;
  int _vmMicros = 0;
  int _vmInstructions = 0;
  int _slowVmSamples = 0;
  int _convertSamples = 0;
  int _convertMicros = 0;
  int _decodeSamples = 0;
  int _decodeMicros = 0;
  String _lastImageResource = '';
  int _lastImageDecodeMicros = 0;

  final Set<J2meKey> _held = {};

  void _log(String line) {
    // Les jeux Java ME utilisent souvent System.out comme journal de boucle.
    // Ces sorties n'aident pas au diagnostic et peuvent elles-mêmes ralentir le jeu.
    if (line.startsWith('[jeu]')) return;
    final important = RegExp(
      r'(Exception|Erreur|impossible|invalide|manquante|non gérée|non implémentée|introuvable|Audio :)',
      caseSensitive: false,
    ).hasMatch(line);
    if (important && _reportedLogs.add(line)) {
      debugPrint('[J2ME] $line');
    }

    if (_disposed) return;

    final next = [...log.value, line];
    log.value = next.length > 80 ? next.sublist(next.length - 80) : next;
  }

  Future<void> boot() async {
    _log('Chargement des sauvegardes...');

    await rmsStorage.load(rms);

    if (_disposed) return;

    _log('Préparation des polices...');

    final atlas = await FontAtlas.build();
    if (_disposed) return;

    final machine = Vm(package, _log);

    registerNatives(machine);
    midp = registerMidp(
      machine,
      atlas,
      _present,
      onImageDecoded: (resource, elapsedMicros) {
        _lastImageResource = resource;
        _lastImageDecodeMicros = elapsedMicros;
      },
    );
    registerJavaLibrary(machine, audioVolume: audioVolume);
    rms.onChanged = () {
      rmsStorage.save(rms);
    };
    registerRms(machine, rms);

    machine.onExit = () {
      _exitRequested = true;
      _timer?.cancel();
      _timer = null;
      _diagnosticTimer?.cancel();
      _diagnosticTimer = null;
      _log('MIDlet terminé : notifyDestroyed/System.exit appelé par le jeu.');
      if (!exited.value) exited.value = true;
    };
    vm = machine;

    try {
      machine.startMidlet(midlet.className);
    } on JavaThrow catch (e) {
      _log('Démarrage impossible : ${e.cls} ${e.msg ?? ''}');
      return;
    }

    if (_disposed || _exitRequested) return;

    final frameMicros = (1000000 / gameFps).round();
    // Garde un budget d'instructions par seconde proche de l'ancien rythme à 60 FPS.
    var adaptiveMultiplier = 1.0;
    _timer = Timer.periodic(Duration(microseconds: frameMicros), (_) {
      final profileMultiplier = switch (performanceProfile) {
        GamePerformanceProfile.adaptive => adaptiveMultiplier,
        GamePerformanceProfile.balanced => 1.0,
        GamePerformanceProfile.performance => 1.5,
        GamePerformanceProfile.economy => 0.65,
      };
      final budget = (300000 * frameMicros / 16667 * profileMultiplier).round();
      machine.tick(budget: budget);
      _vmSamples++;
      _vmMicros += machine.lastTickDurationMicros;
      _vmInstructions += machine.lastTickInstructions;
      if (machine.lastTickInstructions >= budget * 0.90) _slowVmSamples++;
      if (performanceProfile == GamePerformanceProfile.adaptive) {
        final saturated = machine.lastTickInstructions >= budget * 0.90;
        final vmTime = machine.lastTickDurationMicros;
        if (vmTime > frameMicros * 0.75) {
          adaptiveMultiplier = (adaptiveMultiplier * 0.65).clamp(0.12, 1.8);
        } else if (saturated && vmTime < frameMicros * 0.65) {
          adaptiveMultiplier = (adaptiveMultiplier * 1.04).clamp(0.12, 1.8);
        }
      }
    });
    var lastFrames = 0;
    _diagnosticTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      final frameCount = _decodedFrames;
      diagnostics.value = EmulatorDiagnostics(
        renderFps: (frameCount - lastFrames).toDouble(),
        averageVmMs: _vmSamples == 0 ? 0 : _vmMicros / _vmSamples / 1000,
        averageConvertMs:
            _convertSamples == 0 ? 0 : _convertMicros / _convertSamples / 1000,
        averageDecodeMs:
            _decodeSamples == 0 ? 0 : _decodeMicros / _decodeSamples / 1000,
        vmSaturated: _vmSamples > 0 && _slowVmSamples / _vmSamples > 0.5,
        renderBacklog: _queuedSurface != null,
        bytecodesPerSecond: _vmInstructions.toDouble(),
        vmLocation: machine.lastMethodLabel,
        lastImageResource: _lastImageResource,
        lastImageDecodeMs: _lastImageDecodeMicros / 1000,
      );
      lastFrames = frameCount;
      _vmSamples = 0;
      _vmMicros = 0;
      _vmInstructions = 0;
      _slowVmSamples = 0;
      _convertSamples = 0;
      _convertMicros = 0;
      _decodeSamples = 0;
      _decodeMicros = 0;
    });
  }

  /// Présente la dernière surface disponible.
  void _present(Surface surface) {
    if (_disposed) return;

    // Pendant le décodage, on garde uniquement la dernière surface.
    // La conversion des pixels sera faite lorsqu'elle pourra être affichée.
    if (_decoding) {
      _queuedSurface = surface;
      return;
    }

    final convertWatch = Stopwatch()..start();
    final requiredBytes = surface.w * surface.h * 4;
    if (_rgbaBuffer?.length != requiredBytes) {
      _rgbaBuffer = Uint8List(requiredBytes);
    }
    final rgba = _rgbaBuffer!;
    // Les octets ARGB en mémoire sont BGRA sur iOS (little-endian).
    // Copie native vers le tampon réutilisé, sans conversion Dart par pixel.
    final sourceBytes = surface.px.buffer.asUint8List(
      surface.px.offsetInBytes,
      requiredBytes,
    );
    rgba.setRange(0, requiredBytes, sourceBytes);

    _convertSamples++;
    _convertMicros += convertWatch.elapsedMicroseconds;

    _decode(rgba, surface.w, surface.h);
  }

  void _decode(Uint8List rgba, int width, int height) {
    if (_disposed || _decoding) return;

    _decoding = true;
    final decodeWatch = Stopwatch()..start();

    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.bgra8888,
      (image) {
        if (_disposed) {
          image.dispose();
          _queuedSurface = null;
          _decoding = false;
          return;
        }

        final previous = frame.value;
        frame.value = image;
        _decodedFrames++;
        _decodeSamples++;
        _decodeMicros += decodeWatch.elapsedMicroseconds;

        if (previous != null) {
          // Laisse le temps à Flutter de terminer l'affichage précédent.
          Future.delayed(
            const Duration(milliseconds: 200),
            previous.dispose,
          );
        }

        _decoding = false;

        // Si plusieurs images sont arrivées, seule la dernière est traitée.
        final queued = _queuedSurface;
        _queuedSurface = null;

        if (queued != null) {
          _present(queued);
        }
      },
    );
  }

  /// Appelé par l'interface à chaque appui ou relâchement.
  void key(J2meKey key, bool down) {
    if (_disposed) return;

    if (down) {
      if (!_held.add(key)) return;
    } else {
      if (!_held.remove(key)) return;
    }

    midp?.key(key.keyCode, down);
  }

  void dispose() {
    if (_disposed) return;

    _disposed = true;

    rmsStorage.save(rms);

    _timer?.cancel();
    _timer = null;
    _diagnosticTimer?.cancel();
    _diagnosticTimer = null;

    _queuedSurface = null;
    _rgbaBuffer = null;
    _held.clear();

    frame.value?.dispose();
    frame.dispose();
    log.dispose();
    exited.dispose();
    diagnostics.dispose();
  }
}
