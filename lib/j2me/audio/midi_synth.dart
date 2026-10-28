import 'dart:math' as math;
import 'dart:typed_data';

/// Renders a Standard MIDI File to mono PCM WAV for AVPlayer/audio players
/// that do not support MIDI streams directly.
Uint8List renderMidiToWav(Uint8List input) {
  if (input.length < 14 || !_ascii(input, 0, 'MThd')) {
    throw const FormatException('Fichier MIDI Standard invalide (MThd absent).');
  }

  final headerLength = _u32(input, 4);
  if (headerLength < 6 || 8 + headerLength > input.length) {
    throw const FormatException('En-tête MIDI invalide.');
  }
  final format = _u16(input, 8);
  final trackCount = _u16(input, 10);
  final division = _u16(input, 12);
  if (format > 1 || trackCount == 0 || (division & 0x8000) != 0 || division == 0) {
    throw const FormatException('Format ou résolution MIDI non pris en charge.');
  }

  var position = 8 + headerLength;
  final events = <_MidiEvent>[];
  var order = 0;
  var maxTick = 0;
  for (var track = 0; track < trackCount; track++) {
    while (position + 8 <= input.length && !_ascii(input, position, 'MTrk')) {
      final size = _u32(input, position + 4);
      position += 8 + size;
    }
    if (position + 8 > input.length) {
      throw const FormatException('Piste MIDI manquante ou tronquée.');
    }
    final size = _u32(input, position + 4);
    final end = position + 8 + size;
    if (end > input.length) throw const FormatException('Piste MIDI tronquée.');
    position += 8;
    var tick = 0;
    var runningStatus = 0;

    while (position < end) {
      final deltaCursor = _Cursor(position);
      tick += _readVlq(input, end, deltaCursor).value;
      position = deltaCursor.position;
      if (position >= end) break;

      var status = input[position++];
      int? firstData;
      if (status < 0x80) {
        if (runningStatus == 0) {
          throw const FormatException('Running status MIDI invalide.');
        }
        firstData = status;
        status = runningStatus;
      } else if (status < 0xF0) {
        runningStatus = status;
      }

      if (status == 0xFF) {
        if (position >= end) break;
        final type = input[position++];
        final lengthCursor = _Cursor(position);
        final length = _readVlq(input, end, lengthCursor).value;
        position = lengthCursor.position;
        if (position + length > end) {
          throw const FormatException('Événement MIDI méta tronqué.');
        }
        if (type == 0x51 && length == 3) {
          final tempo = (input[position] << 16) |
              (input[position + 1] << 8) |
              input[position + 2];
          if (tempo > 0) {
            events.add(_MidiEvent(tick, order++, tempoMicrosPerQuarter: tempo));
          }
        }
        position += length;
        continue;
      }

      if (status == 0xF0 || status == 0xF7) {
        final lengthCursor = _Cursor(position);
        final length = _readVlq(input, end, lengthCursor).value;
        position = lengthCursor.position + length;
        if (position > end) throw const FormatException('SysEx MIDI tronqué.');
        runningStatus = 0;
        continue;
      }

      if (status >= 0xF0) {
        final count = switch (status) {
          0xF1 || 0xF3 => 1,
          0xF2 => 2,
          _ => 0,
        };
        position += count - (firstData == null ? 0 : 1);
        if (position > end) throw const FormatException('Événement MIDI tronqué.');
        runningStatus = 0;
        continue;
      }

      final command = status & 0xF0;
      final channel = status & 0x0F;
      final dataCount = command == 0xC0 || command == 0xD0 ? 1 : 2;
      final data1 = firstData ?? _readDataByte(input, end, position++);
      final data2 = dataCount == 2 ? _readDataByte(input, end, position++) : 0;
      events.add(_MidiEvent(
        tick,
        order++,
        command: command,
        channel: channel,
        data1: data1,
        data2: data2,
      ));
    }
    maxTick = math.max(maxTick, tick);
    position = end;
  }

  if (events.isEmpty) throw const FormatException('Le fichier MIDI ne contient aucun événement.');
  events.sort((a, b) => a.tick != b.tick ? a.tick.compareTo(b.tick) : a.order.compareTo(b.order));

  var tempo = 500000;
  var previousTick = 0;
  var elapsedMicros = 0.0;
  for (final event in events) {
    elapsedMicros += (event.tick - previousTick) * tempo / division;
    event.timeMicros = elapsedMicros.round();
    previousTick = event.tick;
    if (event.tempoMicrosPerQuarter != null) tempo = event.tempoMicrosPerQuarter!;
  }
  elapsedMicros += (maxTick - previousTick) * tempo / division;
  final sequenceEnd = elapsedMicros.round();

  final programs = List<int>.filled(16, 0);
  final volumes = List<int>.filled(16, 100);
  final bends = List<int>.filled(16, 8192);
  final sustain = List<bool>.filled(16, false);
  final active = <String, List<_VoiceSpec>>{};
  final held = List<List<_VoiceSpec>>.generate(16, (_) => <_VoiceSpec>[]);
  final voices = <_VoiceSpec>[];

  void endVoice(_VoiceSpec voice, int time) {
    voice.endMicros = math.max(voice.startMicros + 10000, time);
    voices.add(voice);
  }

  void releaseChannel(int channel, int time) {
    final keys = active.keys.where((key) => key.startsWith('$channel:')).toList();
    for (final key in keys) {
      for (final voice in active.remove(key)!) {
        endVoice(voice, time);
      }
    }
    for (final voice in held[channel]) {
      endVoice(voice, time);
    }
    held[channel].clear();
  }

  for (final event in events) {
    final command = event.command;
    if (command == null) continue;
    final channel = event.channel!;
    final time = event.timeMicros;
    switch (command) {
      case 0x80:
      case 0x90:
        final pitch = event.data1!;
        final isOn = command == 0x90 && event.data2! > 0;
        final key = '$channel:$pitch';
        if (isOn) {
          final bend = (bends[channel] - 8192) / 8192.0 * 2.0;
          active.putIfAbsent(key, () => <_VoiceSpec>[]).add(_VoiceSpec(
                channel: channel,
                pitch: pitch,
                velocity: event.data2!,
                program: programs[channel],
                channelVolume: volumes[channel],
                pitchBendSemitones: bend,
                startMicros: time,
              ));
        } else {
          final queue = active[key];
          if (queue != null && queue.isNotEmpty) {
            final voice = queue.removeAt(0);
            if (queue.isEmpty) active.remove(key);
            if (sustain[channel]) {
              held[channel].add(voice);
            } else {
              endVoice(voice, time);
            }
          }
        }
      case 0xB0:
        final controller = event.data1!;
        final value = event.data2!;
        if (controller == 7) volumes[channel] = value * 100 ~/ 127;
        if (controller == 64) {
          final down = value >= 64;
          if (sustain[channel] && !down) {
            for (final voice in held[channel]) {
              endVoice(voice, time);
            }
            held[channel].clear();
          }
          sustain[channel] = down;
        }
        if (controller == 120 || controller == 123) releaseChannel(channel, time);
      case 0xC0:
        programs[channel] = event.data1!;
      case 0xE0:
        bends[channel] = event.data1! | (event.data2! << 7);
    }
  }

  for (final entry in active.values) {
    for (final voice in entry) {
      endVoice(voice, sequenceEnd);
    }
  }
  for (var channel = 0; channel < 16; channel++) {
    for (final voice in held[channel]) {
      endVoice(voice, sequenceEnd);
    }
  }
  if (voices.isEmpty) throw const FormatException('Le fichier MIDI ne contient aucune note.');

  const sampleRate = 22050;
  const maximumDurationMicros = 180000000;
  var endMicros = 0;
  for (final voice in voices) {
    endMicros = math.max(endMicros, voice.endMicros + 90000);
  }
  if (endMicros <= 0 || endMicros > maximumDurationMicros) {
    throw const FormatException('Durée MIDI hors limites (maximum 180 secondes).');
  }
  voices.sort((a, b) => a.startMicros.compareTo(b.startMicros));
  final sampleCount = (endMicros * sampleRate / 1000000).ceil();
  final dataSize = sampleCount * 2;
  final output = ByteData(44 + dataSize);
  _writeAscii(output, 0, 'RIFF');
  output.setUint32(4, 36 + dataSize, Endian.little);
  _writeAscii(output, 8, 'WAVE');
  _writeAscii(output, 12, 'fmt ');
  output.setUint32(16, 16, Endian.little);
  output.setUint16(20, 1, Endian.little);
  output.setUint16(22, 1, Endian.little);
  output.setUint32(24, sampleRate, Endian.little);
  output.setUint32(28, sampleRate * 2, Endian.little);
  output.setUint16(32, 2, Endian.little);
  output.setUint16(34, 16, Endian.little);
  _writeAscii(output, 36, 'data');
  output.setUint32(40, dataSize, Endian.little);

  final sampleVoices = [
    for (final voice in voices)
      _MidiVoice(
        voice,
        startSample: voice.startMicros * sampleRate ~/ 1000000,
        endSample: voice.endMicros * sampleRate ~/ 1000000,
        sampleRate: sampleRate,
      ),
  ];
  final activeVoices = <_MidiVoice>[];
  var nextVoice = 0;
  for (var sample = 0; sample < sampleCount; sample++) {
    while (nextVoice < sampleVoices.length && sampleVoices[nextVoice].startSample <= sample) {
      activeVoices.add(sampleVoices[nextVoice++]);
    }
    activeVoices.removeWhere((voice) => voice.endSample <= sample);
    var mixed = 0.0;
    for (final voice in activeVoices) {
      mixed += voice.nextSample(sample);
    }
    output.setInt16(44 + sample * 2, mixed.round().clamp(-32768, 32767), Endian.little);
  }
  return output.buffer.asUint8List();
}

class _MidiEvent {
  _MidiEvent(this.tick, this.order,
      {this.command, this.channel, this.data1, this.data2, this.tempoMicrosPerQuarter});
  final int tick;
  final int order;
  final int? command;
  final int? channel;
  final int? data1;
  final int? data2;
  final int? tempoMicrosPerQuarter;
  int timeMicros = 0;
}

class _VoiceSpec {
  _VoiceSpec({required this.channel, required this.pitch, required this.velocity,
    required this.program, required this.channelVolume, required this.pitchBendSemitones,
    required this.startMicros});
  final int channel;
  final int pitch;
  final int velocity;
  final int program;
  final int channelVolume;
  final double pitchBendSemitones;
  final int startMicros;
  int endMicros = 0;
}

class _MidiVoice {
  _MidiVoice(this.spec, {required this.startSample, required this.endSample, required int sampleRate})
      : _step = 2 * math.pi * 440 * math.pow(2, (spec.pitch + spec.pitchBendSemitones - 69) / 12) / sampleRate,
        _drum = spec.channel == 9,
        _seed = (spec.pitch * 7919 + spec.velocity * 104729 + 1) & 0x7fffffff;
  final _VoiceSpec spec;
  final int startSample;
  final int endSample;
  final double _step;
  final bool _drum;
  int _seed;
  double _phase = 0;

  double nextSample(int sample) {
    final age = sample - startSample;
    final remaining = endSample - sample;
    final attack = math.min(1.0, age / 90.0);
    final release = math.min(1.0, remaining / 1100.0);
    final velocity = spec.velocity / 127.0;
    final channelGain = spec.channelVolume / 100.0;
    final timbre = switch (spec.program ~/ 8) {
      0 || 1 => math.sin(_phase) + 0.34 * math.sin(_phase * 2) + 0.14 * math.sin(_phase * 3),
      2 || 3 => math.sin(_phase) + 0.25 * math.sin(_phase * 2),
      4 || 5 => 2 / math.pi * math.asin(math.sin(_phase)),
      _ => 0.72 * math.sin(_phase) + 0.28 * math.sin(_phase * 2),
    };
    double signal;
    if (_drum) {
      _seed = (1103515245 * _seed + 12345) & 0x7fffffff;
      final noise = ((_seed & 0xffff) / 32767.5) - 1.0;
      final decay = math.exp(-age / (spec.pitch < 40 ? 1700.0 : 550.0));
      signal = spec.pitch < 40 ? math.sin(_phase) * decay : noise * decay;
    } else {
      signal = timbre;
    }
    _phase += _step;
    final instrumentDecay = spec.program < 8 || (spec.program >= 24 && spec.program < 32)
        ? math.exp(-age / 180000.0)
        : 1.0;
    return signal * attack * release * instrumentDecay * velocity * channelGain * 4000;
  }
}

class _Cursor {
  _Cursor(this.position);
  int position;
}

class _VarLength {
  const _VarLength(this.value);
  final int value;
}

_VarLength _readVlq(Uint8List data, int end, _Cursor cursor) {
  var value = 0;
  for (var i = 0; i < 4; i++) {
    if (cursor.position >= end) throw const FormatException('Valeur MIDI tronquée.');
    final byte = data[cursor.position++];
    value = (value << 7) | (byte & 0x7f);
    if ((byte & 0x80) == 0) return _VarLength(value);
  }
  throw const FormatException('Valeur MIDI trop longue.');
}

int _readDataByte(Uint8List input, int end, int index) {
  if (index >= end || input[index] >= 0x80) {
    throw const FormatException('Donnée MIDI invalide.');
  }
  return input[index];
}

int _u16(Uint8List data, int offset) => (data[offset] << 8) | data[offset + 1];
int _u32(Uint8List data, int offset) =>
    (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
bool _ascii(Uint8List data, int offset, String text) =>
    data.length >= offset + text.length &&
    List.generate(text.length, (i) => data[offset + i] == text.codeUnitAt(i)).every((v) => v);

void _writeAscii(ByteData data, int offset, String text) {
  for (var i = 0; i < text.length; i++) {
    data.setUint8(offset + i, text.codeUnitAt(i));
  }
}
