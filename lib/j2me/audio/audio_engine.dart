import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path_provider/path_provider.dart';

import 'midi_synth.dart';

class AudioEngine {
  AudioEngine({this.initialVolume = 100, this.onDiagnostic});

  final int initialVolume;
  final void Function(String message)? onDiagnostic;
  final Map<int, _AudioInstance> _players = {};
  int _nextId = 1;

  int createPlayer({
    Uint8List? data,
    String? mimeType,
    String sourceDescription = 'source inconnue',
  }) {
    final id = _nextId++;
    final detectedMimeType = _audioMimeType(data, mimeType);

    final player = AudioPlayer();

    _players[id] = _AudioInstance(
      player: player,
      data: data,
      mimeType: detectedMimeType,
      sourceDescription: sourceDescription,
      volume: initialVolume.clamp(0, 100) / 100.0,
    );

    return id;
  }

  Stream<void> onComplete(int id) {
    final instance = _players[id];

    if (instance == null) {
      return const Stream.empty();
    }

    return instance.player.onPlayerComplete;
  }

  void updateSource(int id, Uint8List data, {required String mimeType}) {
    final instance = _players[id];
    if (instance == null) return;
    instance.data = data;
    instance.mimeType = mimeType;
    // ToneControl sequences are set before the player is started, so the
    // native temporary file has not yet been created.
    instance.sourceFile = null;
  }

  Future<void> start(int id) async {
    final instance = _players[id];
    if (instance == null) return;

    var data = instance.data;
    if (data == null || data.isEmpty) {
      // Manager.createPlayer logs the missing/null source at the Java API
      // boundary. Keep this layer quiet to avoid a duplicate message.
      if (instance.sourceDescription == 'source inconnue') {
        onDiagnostic?.call(
          'Audio : lecteur $id (${instance.sourceDescription}) démarré sans données audio.',
        );
      }
      return;
    }

    if (_isMidi(data, instance.mimeType)) {
      try {
        data = await compute<Uint8List, Uint8List>(renderMidiToWav, data);
        instance.data = data;
        instance.mimeType = 'audio/wav';
        instance.sourceFile = null;
      } catch (error) {
        onDiagnostic?.call('Audio : MIDI non décodable (${instance.sourceDescription}) : $error');
        return;
      }
    }

    try {
      await instance.player.setVolume(instance.muted ? 0.0 : instance.volume);
      final context = AudioContext(
        android: const AudioContextAndroid(
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
        ),
        iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
      );

      // AVPlayer ne lit pas les fichiers MIDI. Ils sont synthétisés ci-dessus;
      // les autres formats sont transmis avec leur extension et leur MIME.
      if (Platform.isIOS || Platform.isMacOS) {
        final file = await _fileFor(instance, id);
        await instance.player.play(
          DeviceFileSource(file.path, mimeType: instance.mimeType),
          ctx: context,
        );
      } else {
        await instance.player.play(
          BytesSource(data, mimeType: instance.mimeType),
          ctx: context,
        );
      }
    } catch (error) {
      onDiagnostic?.call('Audio : lecture impossible (${instance.sourceDescription}) : $error');
    }
  }

  Future<void> stop(int id) async {
    final instance = _players[id];
    if (instance == null) return;

    await instance.player.stop();
  }

  Future<void> pause(int id) async {
    final instance = _players[id];
    if (instance == null) return;

    await instance.player.pause();
  }

  Future<void> setVolume(int id, int level) async {
    final instance = _players[id];
    if (instance == null) return;

    final volume = (level.clamp(0, 100)) / 100.0;

    instance.volume = volume;

    if (!instance.muted) {
      await instance.player.setVolume(volume);
    }
  }

  Future<void> setMute(int id, bool muted) async {
    final instance = _players[id];
    if (instance == null) return;

    instance.muted = muted;

    await instance.player.setVolume(
      muted ? 0.0 : instance.volume,
    );
  }

  Future<void> setLoopCount(int id, int count) async {
    final instance = _players[id];
    if (instance == null) return;

    instance.loopCount = count;

    if (count == -1) {
      await instance.player.setReleaseMode(ReleaseMode.loop);
    } else {
      await instance.player.setReleaseMode(ReleaseMode.stop);
    }
  }

  int getVolume(int id) {
    return ((_players[id]?.volume ?? 1.0) * 100).round();
  }

  bool isMuted(int id) {
    return _players[id]?.muted ?? false;
  }

  Future<Duration?> getDuration(int id) async {
    final instance = _players[id];
    if (instance == null) return null;

    return instance.player.getDuration();
  }

  Future<Duration?> getPosition(int id) async {
    final instance = _players[id];
    if (instance == null) return null;

    return instance.player.getCurrentPosition();
  }

  Future<void> setPosition(int id, Duration position) async {
    final instance = _players[id];
    if (instance == null) return;

    await instance.player.seek(position);
  }

  Future<void> close(int id) async {
    final instance = _players.remove(id);
    if (instance == null) return;

    await instance.player.stop();
    await instance.player.dispose();
    final file = instance.sourceFile;
    if (file != null && await file.exists()) await file.delete();
  }

  Future<void> dispose() async {
    final ids = _players.keys.toList();

    for (final id in ids) {
      await close(id);
    }
  }
}

Future<File> _fileFor(_AudioInstance instance, int id) async {
  final existing = instance.sourceFile;
  if (existing != null && await existing.exists()) return existing;

  final directory = await getTemporaryDirectory();
  final extension = switch (instance.mimeType) {
    'audio/wav' || 'audio/x-wav' || 'audio/wave' => 'wav',
    'audio/mpeg' || 'audio/mp3' => 'mp3',
    'audio/mp4' || 'audio/aac' => 'm4a',
    'audio/ogg' || 'audio/opus' => 'ogg',
    'audio/3gpp' => '3gp',
    'audio/amr' => 'amr',
    'audio/midi' || 'audio/x-midi' => 'mid',
    _ => 'audio',
  };
  final file = File('${directory.path}/pixelbox_audio_$id.$extension');
  await file.writeAsBytes(instance.data!, flush: true);
  instance.sourceFile = file;
  return file;
}

String? _audioMimeType(Uint8List? data, String? provided) {
  if (provided != null && provided.trim().isNotEmpty) {
    final type = provided.split(';').first.trim().toLowerCase();
    if (type.startsWith('audio/')) return type;
  }
  if (data == null || data.length < 4) return null;
  bool ascii(int offset, String value) =>
      data.length >= offset + value.length &&
      List.generate(value.length, (i) => data[offset + i] == value.codeUnitAt(i)).every((v) => v);

  if (ascii(0, 'RIFF') && ascii(8, 'WAVE')) return 'audio/wav';
  if (ascii(0, 'ID3') || (data[0] == 0xFF && (data[1] & 0xE0) == 0xE0)) return 'audio/mpeg';
  if (ascii(0, 'OggS')) return 'audio/ogg';
  if (ascii(0, 'fLaC')) return 'audio/flac';
  if (ascii(0, 'MThd')) return 'audio/midi';
  if (ascii(0, '#!AMR')) return 'audio/amr';
  if (ascii(4, 'ftyp')) return 'audio/mp4';
  return null;
}

bool _isMidi(Uint8List data, String? mimeType) =>
    mimeType == 'audio/midi' ||
    mimeType == 'audio/x-midi' ||
    (data.length >= 4 &&
        data[0] == 0x4d &&
        data[1] == 0x54 &&
        data[2] == 0x68 &&
        data[3] == 0x64);

class _AudioInstance {
  final AudioPlayer player;
  Uint8List? data;
  String? mimeType;
  final String sourceDescription;
  File? sourceFile;

  double volume = 1.0;
  bool muted = false;
  int loopCount = 1;

  _AudioInstance({
    required this.player,
    this.data,
    this.mimeType,
    required this.sourceDescription,
    this.volume = 1.0,
  });
}
