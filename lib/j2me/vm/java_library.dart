import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'vm.dart';
import '../audio/audio_engine.dart';

/// Natives complémentaires, celles que presque tous les jeux J2ME appellent :
/// ressources du JAR (getResourceAsStream), flux de données, Runtime, Math,
/// Hashtable / Stack / Enumeration, média (audio), String/StringBuffer (suite)
/// et classes Nokia.
///
/// À appeler APRÈS registerNatives() et registerMidp().
void registerJavaLibrary(Vm vm, {int audioVolume = 100}) {
  _ensureMidlet(vm);
  _stringMore(vm);
  _integerMore(vm);
  _classAndResources(vm);
  _streams(vm);
  _runtime(vm);
  _mathMore(vm);
  _collections(vm);
  _media(vm, audioVolume: audioVolume);
  _nokia(vm);
}

/// Garde-fou : la classe de base de tous les jeux doit exister, avec ses
/// méthodes natives. Si registerNatives() ne l'a pas définie, on le fait ici
/// (et on le dit dans la console, pour retrouver la cause).
void _ensureMidlet(Vm vm) {
  const c = 'javax/microedition/midlet/MIDlet';
  if (!vm.classes.containsKey(c)) {
    vm.defineClass(c, 'java/lang/Object');
    vm.log('MIDlet absent après registerNatives() : défini par java_library.');
  }
  final n = vm.natives;
  n.putIfAbsent('$c.<init>()V', () => (vm, t, a) => null);
  n.putIfAbsent('$c.notifyPaused()V', () => (vm, t, a) => null);
  n.putIfAbsent('$c.resumeRequest()V', () => (vm, t, a) => null);
  n.putIfAbsent(
      '$c.notifyDestroyed()V',
      () => (vm, t, a) {
            vm.log('MIDlet.notifyDestroyed()');
            vm.onExit?.call();
            return null;
          });
  n.putIfAbsent(
      '$c.getAppProperty(Ljava/lang/String;)Ljava/lang/String;',
      () => (vm, t, a) {
            final v = vm.jar.manifest[a[1] as String];
            return v == null ? null : vm.intern(v);
          });
  vm.log(
      'Moteur : ${vm.classes.length} classes, ${vm.natives.length} natives.');
}

// ------------------------------------------------------------------ états

class _In {
  _In(this.data);

  final Uint8List data;
  int pos = 0;
  int markPos = 0;
}

class _Out {
  final List<int> bytes = [];
}

class _Iter {
  _Iter(this.items);

  final List<Object?> items;
  int i = 0;
}

class _Entry {
  _Entry(this.key, this.value);

  final Object? key;
  Object? value;
}

class _PlayerState {
  final int audioId;
  final String sourceDescription;
  final bool isDeviceLocator;
  bool warnedAboutUnsupportedDevice = false;
  bool toneSequenceSet = false;

  int state = 100; // UNREALIZED
  int loopCount = 1;

  /// Position de lecture en millisecondes (l'API Java la donne en microsecondes).
  int mediaTimeMs = 0;
  int durationMs = -1;
  JObject? listener;
  _PlayerState(this.audioId,
      {this.sourceDescription = 'InputStream', this.isDeviceLocator = false});
}

Int8List _i8(Object? o) {
  if (o == null) throw JavaThrow('java/lang/NullPointerException');
  return (o as JArray).data as Int8List;
}

Uint8List _u8(Object? o) {
  final d = _i8(o);
  return d.buffer.asUint8List(d.offsetInBytes, d.length);
}

String _normalizeJarPath(String path) {
  var value = path.replaceAll('\\', '/');
  try {
    value = Uri.decodeComponent(value);
  } on FormatException {
    // Keep the original spelling if the resource has malformed escaping.
  }
  final parts = <String>[];
  for (final part in value.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

String? _jarResourceKey(Map<String, Uint8List> files, String path) {
  final wanted = _normalizeJarPath(path);
  if (files.containsKey(wanted)) return wanted;
  final lower = wanted.toLowerCase();
  for (final key in files.keys) {
    final normalized = _normalizeJarPath(key);
    if (normalized.toLowerCase() == lower) return key;
  }

  // Some older MIDlets pass a package-relative name although the resource is
  // stored at the JAR root (or in another resource directory). Only use this
  // compatibility fallback when the basename is unique in the archive.
  final basename = wanted.split('/').last.toLowerCase();
  if (basename.isEmpty) return null;
  String? match;
  for (final key in files.keys) {
    if (_normalizeJarPath(key).split('/').last.toLowerCase() != basename) {
      continue;
    }
    if (match != null) return null;
    match = key;
  }
  return match;
}

// ------------------------------------------------- Class et ressources du JAR

void _classAndResources(Vm vm) {
  final n = vm.natives;
  vm.defineClass('java/lang/Class', 'java/lang/Object');
  final classClass = vm.classes['java/lang/Class']!;
  final cache = <JClass, JObject>{};
  final missingResources = <String>{};
  JObject classObj(JClass c) =>
      cache.putIfAbsent(c, () => JObject(classClass)..native = c);

  n['java/lang/Object.getClass()Ljava/lang/Class;'] =
      (vm, t, a) => classObj(vm.classOf(a[0]!));

  n['java/lang/Class.getName()Ljava/lang/String;'] = (vm, t, a) {
    final c = (a[0] as JObject).native as JClass;
    return vm.intern(c.name.replaceAll('/', '.'));
  };

  // getClass().getResourceAsStream("/niveau1.dat") : le chargement de
  // ressources le plus répandu dans les jeux J2ME.
  n['java/lang/Class.getResourceAsStream(Ljava/lang/String;)Ljava/io/InputStream;'] =
      (vm, t, a) {
    final raw = a[1];
    if (raw == null) throw JavaThrow('java/lang/NullPointerException');
    final className = ((a[0] as JObject).native as JClass).name;
    var key = raw as String;
    if (key.startsWith('/')) {
      key = key.substring(1);
    } else {
      final slash = className.lastIndexOf('/');
      if (slash >= 0) key = '${className.substring(0, slash + 1)}$key';
    }
    final jarKey = _jarResourceKey(vm.jar.files, key);
    final bytes = jarKey == null ? null : vm.jar.files[jarKey];
    if (bytes == null) {
      final request = '$className:$key';
      if (missingResources.add(request)) {
        final candidates = vm.jar.files.keys
            .where((name) => RegExp(
                    r'\.(wav|mp3|m4a|aac|ogg|amr|mid|midi|3gp)$',
                    caseSensitive: false)
                .hasMatch(name))
            .take(8)
            .join(', ');
        vm.log(
            'Audio : getResourceAsStream ne trouve pas "$key" (classe $className).'
            '${candidates.isEmpty ? '' : ' Ressources audio du JAR : $candidates'}');
      }
      return null;
    }
    if (_normalizeJarPath(jarKey!) != _normalizeJarPath(key)) {
      vm.log('Audio : ressource "$key" résolue vers "$jarKey" dans le JAR.');
    }
    return JObject(vm.classes['java/io/ByteArrayInputStream']!)
      ..native = _In(bytes);
  };
}

// ------------------------------------------------------------------ flux

void _streams(Vm vm) {
  final n = vm.natives;
  vm.defineClass('java/io/InputStream', 'java/lang/Object');
  vm.defineClass('java/io/ByteArrayInputStream', 'java/io/InputStream');
  vm.defineClass('java/io/DataInputStream', 'java/io/InputStream');
  vm.defineClass('java/io/OutputStream', 'java/lang/Object');
  vm.defineClass('java/io/ByteArrayOutputStream', 'java/io/OutputStream');
  vm.defineClass('java/io/DataOutputStream', 'java/io/OutputStream');
  vm.defineClass('java/io/EOFException', 'java/io/IOException');

  _In inp(List<Object?> a) {
    final s = (a[0] as JObject).native;
    if (s is! _In) throw JavaThrow('java/io/IOException', 'flux illisible');
    return s;
  }

  _Out outp(List<Object?> a) {
    final s = (a[0] as JObject).native;
    if (s is! _Out) throw JavaThrow('java/io/IOException', 'flux illisible');
    return s;
  }

  // -------------------------------------------------------------- entrée
  const ins = 'java/io/InputStream';
  n['$ins.<init>()V'] = (vm, t, a) => null;
  n['java/io/ByteArrayInputStream.<init>([B)V'] = (vm, t, a) {
    (a[0] as JObject).native = _In(_u8(a[1]));
    return null;
  };
  n['java/io/ByteArrayInputStream.<init>([BII)V'] = (vm, t, a) {
    final d = _u8(a[1]);
    final off = a[2] as int;
    final len = a[3] as int;
    if (off < 0 || len < 0 || off + len > d.length) {
      throw JavaThrow('java/lang/IndexOutOfBoundsException');
    }
    (a[0] as JObject).native = _In(Uint8List.sublistView(d, off, off + len));
    return null;
  };
  n['java/io/DataInputStream.<init>(Ljava/io/InputStream;)V'] = (vm, t, a) {
    final src = a[1];
    if (src == null) throw JavaThrow('java/lang/NullPointerException');
    (a[0] as JObject).native = (src as JObject).native;
    return null;
  };

  n['$ins.read()I'] = (vm, t, a) {
    final s = inp(a);
    return s.pos < s.data.length ? s.data[s.pos++] : -1;
  };

  int readInto(List<Object?> a, int off, int len) {
    final s = inp(a);
    final arr = _i8(a[1]);
    if (off < 0 || len < 0 || off + len > arr.length) {
      throw JavaThrow('java/lang/IndexOutOfBoundsException');
    }
    if (len == 0) return 0;
    final left = s.data.length - s.pos;
    if (left <= 0) return -1;
    final k = math.min(left, len);
    for (var i = 0; i < k; i++) {
      arr[off + i] = s.data[s.pos + i];
    }
    s.pos += k;
    return k;
  }

  n['$ins.read([B)I'] = (vm, t, a) => readInto(a, 0, _i8(a[1]).length);
  n['$ins.read([BII)I'] = (vm, t, a) => readInto(a, a[2] as int, a[3] as int);
  n['$ins.available()I'] = (vm, t, a) {
    final s = inp(a);
    return s.data.length - s.pos;
  };
  n['$ins.skip(J)J'] = (vm, t, a) {
    final s = inp(a);
    final k = math.max(0, math.min(a[1] as int, s.data.length - s.pos));
    s.pos += k;
    return k;
  };
  n['$ins.close()V'] = (vm, t, a) => null;
  n['$ins.markSupported()Z'] = (vm, t, a) => 1;
  n['$ins.mark(I)V'] = (vm, t, a) {
    final s = inp(a);
    s.markPos = s.pos;
    return null;
  };
  n['$ins.reset()V'] = (vm, t, a) {
    final s = inp(a);
    s.pos = s.markPos;
    return null;
  };

  // Lectures typées (DataInputStream).
  const di = 'java/io/DataInputStream';
  int take(List<Object?> a, int k) {
    final s = inp(a);
    if (s.pos + k > s.data.length) throw JavaThrow('java/io/EOFException');
    final p = s.pos;
    s.pos += k;
    return p;
  }

  ByteData view(List<Object?> a) => ByteData.sublistView(inp(a).data);

  n['$di.readByte()B'] = (vm, t, a) {
    final p = take(a, 1);
    return inp(a).data[p].toSigned(8);
  };
  n['$di.readUnsignedByte()I'] = (vm, t, a) {
    final p = take(a, 1);
    return inp(a).data[p];
  };
  n['$di.readBoolean()Z'] = (vm, t, a) {
    final p = take(a, 1);
    return inp(a).data[p] != 0 ? 1 : 0;
  };
  n['$di.readShort()S'] = (vm, t, a) {
    final p = take(a, 2);
    return view(a).getInt16(p);
  };
  n['$di.readUnsignedShort()I'] = (vm, t, a) {
    final p = take(a, 2);
    return view(a).getUint16(p);
  };
  n['$di.readChar()C'] = (vm, t, a) {
    final p = take(a, 2);
    return view(a).getUint16(p);
  };
  n['$di.readInt()I'] = (vm, t, a) {
    final p = take(a, 4);
    return view(a).getInt32(p);
  };
  n['$di.readLong()J'] = (vm, t, a) {
    final p = take(a, 8);
    return view(a).getInt64(p);
  };
  n['$di.readFloat()F'] = (vm, t, a) {
    final p = take(a, 4);
    return view(a).getFloat32(p);
  };
  n['$di.readDouble()D'] = (vm, t, a) {
    final p = take(a, 8);
    return view(a).getFloat64(p);
  };
  n['$di.readUTF()Ljava/lang/String;'] = (vm, t, a) {
    final p = take(a, 2);
    final len = view(a).getUint16(p);
    final q = take(a, len);
    final bytes = Uint8List.sublistView(inp(a).data, q, q + len);
    return vm.intern(utf8.decode(bytes, allowMalformed: true));
  };

  void fully(List<Object?> a, int off, int len) {
    final s = inp(a);
    final arr = _i8(a[1]);
    if (off < 0 || len < 0 || off + len > arr.length) {
      throw JavaThrow('java/lang/IndexOutOfBoundsException');
    }
    if (s.pos + len > s.data.length) throw JavaThrow('java/io/EOFException');
    for (var i = 0; i < len; i++) {
      arr[off + i] = s.data[s.pos + i];
    }
    s.pos += len;
  }

  n['$di.readFully([B)V'] = (vm, t, a) {
    fully(a, 0, _i8(a[1]).length);
    return null;
  };
  n['$di.readFully([BII)V'] = (vm, t, a) {
    fully(a, a[2] as int, a[3] as int);
    return null;
  };
  n['$di.skipBytes(I)I'] = (vm, t, a) {
    final s = inp(a);
    final k = math.max(0, math.min(a[1] as int, s.data.length - s.pos));
    s.pos += k;
    return k;
  };

  // -------------------------------------------------------------- sortie
  const os = 'java/io/OutputStream';
  n['$os.<init>()V'] = (vm, t, a) => null;
  n['java/io/ByteArrayOutputStream.<init>()V'] = (vm, t, a) {
    (a[0] as JObject).native = _Out();
    return null;
  };
  n['java/io/ByteArrayOutputStream.<init>(I)V'] =
      n['java/io/ByteArrayOutputStream.<init>()V']!;
  n['java/io/DataOutputStream.<init>(Ljava/io/OutputStream;)V'] = (vm, t, a) {
    final dst = a[1];
    if (dst == null) throw JavaThrow('java/lang/NullPointerException');
    (a[0] as JObject).native = (dst as JObject).native;
    return null;
  };

  n['java/io/ByteArrayOutputStream.toByteArray()[B'] =
      (vm, t, a) => JArray('[B', Int8List.fromList(outp(a).bytes));
  n['java/io/ByteArrayOutputStream.size()I'] =
      (vm, t, a) => outp(a).bytes.length;
  n['java/io/ByteArrayOutputStream.reset()V'] = (vm, t, a) {
    outp(a).bytes.clear();
    return null;
  };

  n['$os.write(I)V'] = (vm, t, a) {
    outp(a).bytes.add((a[1] as int) & 0xFF);
    return null;
  };
  n['$os.write([B)V'] = (vm, t, a) {
    outp(a).bytes.addAll(_u8(a[1]));
    return null;
  };
  n['$os.write([BII)V'] = (vm, t, a) {
    final d = _u8(a[1]);
    final off = a[2] as int;
    final len = a[3] as int;
    if (off < 0 || len < 0 || off + len > d.length) {
      throw JavaThrow('java/lang/IndexOutOfBoundsException');
    }
    outp(a).bytes.addAll(Uint8List.sublistView(d, off, off + len));
    return null;
  };
  n['$os.flush()V'] = (vm, t, a) => null;
  n['$os.close()V'] = (vm, t, a) => null;

  // Écritures typées (DataOutputStream), big-endian comme en Java.
  const dout = 'java/io/DataOutputStream';
  void put(List<Object?> a, int v, int count) {
    final out = outp(a).bytes;
    for (var i = count - 1; i >= 0; i--) {
      out.add((v >> (8 * i)) & 0xFF);
    }
  }

  n['$dout.writeByte(I)V'] = (vm, t, a) {
    put(a, a[1] as int, 1);
    return null;
  };
  n['$dout.writeBoolean(Z)V'] = (vm, t, a) {
    put(a, (a[1] as int) != 0 ? 1 : 0, 1);
    return null;
  };
  n['$dout.writeShort(I)V'] = (vm, t, a) {
    put(a, a[1] as int, 2);
    return null;
  };
  n['$dout.writeChar(I)V'] = (vm, t, a) {
    put(a, a[1] as int, 2);
    return null;
  };
  n['$dout.writeInt(I)V'] = (vm, t, a) {
    put(a, a[1] as int, 4);
    return null;
  };
  n['$dout.writeLong(J)V'] = (vm, t, a) {
    put(a, a[1] as int, 8);
    return null;
  };
  n['$dout.writeFloat(F)V'] = (vm, t, a) {
    final bd = ByteData(4)..setFloat32(0, a[1] as double);
    outp(a).bytes.addAll(bd.buffer.asUint8List());
    return null;
  };
  n['$dout.writeDouble(D)V'] = (vm, t, a) {
    final bd = ByteData(8)..setFloat64(0, a[1] as double);
    outp(a).bytes.addAll(bd.buffer.asUint8List());
    return null;
  };
  n['$dout.writeUTF(Ljava/lang/String;)V'] = (vm, t, a) {
    final s = a[1];
    if (s == null) throw JavaThrow('java/lang/NullPointerException');
    final bytes = utf8.encode(s as String);
    if (bytes.length > 65535) {
      throw JavaThrow('java/io/IOException', 'chaîne trop longue');
    }
    put(a, bytes.length, 2);
    outp(a).bytes.addAll(bytes);
    return null;
  };
}

// --------------------------------------------------------------- Runtime

void _runtime(Vm vm) {
  final n = vm.natives;
  vm.defineClass('java/lang/Runtime', 'java/lang/Object');
  final instance = JObject(vm.classes['java/lang/Runtime']!);
  const c = 'java/lang/Runtime';
  n['$c.getRuntime()Ljava/lang/Runtime;'] = (vm, t, a) => instance;
  // Beaucoup de jeux décident de leur cache d'images d'après ces valeurs.
  n['$c.totalMemory()J'] = (vm, t, a) => 8 * 1024 * 1024;
  n['$c.freeMemory()J'] = (vm, t, a) => 6 * 1024 * 1024;
  n['$c.gc()V'] = (vm, t, a) => null;
}

// ------------------------------------------------------------------ Math

void _mathMore(Vm vm) {
  final n = vm.natives;
  const c = 'java/lang/Math';
  n['$c.min(FF)F'] = (vm, t, a) => math.min(a[0] as double, a[1] as double);
  n['$c.max(FF)F'] = (vm, t, a) => math.max(a[0] as double, a[1] as double);
  n['$c.pow(DD)D'] =
      (vm, t, a) => math.pow(a[0] as double, a[1] as double).toDouble();
  n['$c.exp(D)D'] = (vm, t, a) => math.exp(a[0] as double);
  n['$c.log(D)D'] = (vm, t, a) => math.log(a[0] as double);
  n['$c.asin(D)D'] = (vm, t, a) => math.asin(a[0] as double);
  n['$c.acos(D)D'] = (vm, t, a) => math.acos(a[0] as double);
  n['$c.atan(D)D'] = (vm, t, a) => math.atan(a[0] as double);
  n['$c.atan2(DD)D'] = (vm, t, a) => math.atan2(a[0] as double, a[1] as double);
  n['$c.toRadians(D)D'] = (vm, t, a) => (a[0] as double) * math.pi / 180.0;
  n['$c.toDegrees(D)D'] = (vm, t, a) => (a[0] as double) * 180.0 / math.pi;
}

// ----------------------------------------- Enumeration, Hashtable, Stack

Object _hkey(Object? o) {
  if (o == null) throw JavaThrow('java/lang/NullPointerException');
  if (o is String) return o;
  if (o is JObject) {
    final nv = o.native;
    if (nv is int && o.cls.name == 'java/lang/Integer') return ('I', nv);
  }
  return o;
}

void _collections(Vm vm) {
  final n = vm.natives;

  vm.defineClass('java/util/Enumeration', 'java/lang/Object', iface: true);
  vm.defineClass(
    'java/util/NativeEnumeration',
    'java/lang/Object',
    interfaces: ['java/util/Enumeration'],
  );
  final enumCls = vm.classes['java/util/NativeEnumeration']!;
  JObject makeEnum(List<Object?> items) =>
      JObject(enumCls)..native = _Iter(items);

  const en = 'java/util/NativeEnumeration';
  _Iter it(List<Object?> a) => (a[0] as JObject).native as _Iter;
  n['$en.hasMoreElements()Z'] = (vm, t, a) {
    final i = it(a);
    return i.i < i.items.length ? 1 : 0;
  };
  n['$en.nextElement()Ljava/lang/Object;'] = (vm, t, a) {
    final i = it(a);
    if (i.i >= i.items.length) {
      throw JavaThrow('java/util/NoSuchElementException');
    }
    return i.items[i.i++];
  };

  // Vector.elements() et setSize().
  const vc = 'java/util/Vector';
  List<Object?> vec(List<Object?> a) =>
      (a[0] as JObject).native as List<Object?>;
  n['$vc.elements()Ljava/util/Enumeration;'] =
      (vm, t, a) => makeEnum(List<Object?>.of(vec(a)));
  n['$vc.setSize(I)V'] = (vm, t, a) {
    final list = vec(a);
    final k = a[1] as int;
    if (k < 0) {
      throw JavaThrow('java/lang/ArrayIndexOutOfBoundsException', '$k');
    }
    if (k < list.length) {
      list.removeRange(k, list.length);
    } else {
      list.addAll(List<Object?>.filled(k - list.length, null));
    }
    return null;
  };
  n['$vc.capacity()I'] = (vm, t, a) => vec(a).length < 10 ? 10 : vec(a).length;
  n['$vc.ensureCapacity(I)V'] = (vm, t, a) => null;
  n['$vc.trimToSize()V'] = (vm, t, a) => null;
  n['$vc.lastIndexOf(Ljava/lang/Object;)I'] = (vm, t, a) {
    final list = vec(a);
    for (var i = list.length - 1; i >= 0; i--) {
      if (vm.javaEquals(list[i], a[1])) return i;
    }
    return -1;
  };

  // Stack (hérite de Vector : le constructeur est celui de Vector).
  vm.defineClass('java/util/Stack', 'java/util/Vector');
  const sk = 'java/util/Stack';
  n['$sk.push(Ljava/lang/Object;)Ljava/lang/Object;'] = (vm, t, a) {
    vec(a).add(a[1]);
    return a[1];
  };
  n['$sk.pop()Ljava/lang/Object;'] = (vm, t, a) {
    final list = vec(a);
    if (list.isEmpty) throw JavaThrow('java/util/EmptyStackException');
    return list.removeLast();
  };
  n['$sk.peek()Ljava/lang/Object;'] = (vm, t, a) {
    final list = vec(a);
    if (list.isEmpty) throw JavaThrow('java/util/EmptyStackException');
    return list.last;
  };
  n['$sk.empty()Z'] = (vm, t, a) => vec(a).isEmpty ? 1 : 0;
  n['$sk.search(Ljava/lang/Object;)I'] = (vm, t, a) {
    final list = vec(a);
    for (var i = list.length - 1; i >= 0; i--) {
      if (vm.javaEquals(list[i], a[1])) return list.length - i;
    }
    return -1;
  };

  // Hashtable : les clés String et Integer sont comparées par valeur, les
  // autres objets par identité (equals()/hashCode() Java redéfinis ignorés).
  vm.defineClass('java/util/Hashtable', 'java/lang/Object');
  const ht = 'java/util/Hashtable';
  Map<Object, _Entry> table(List<Object?> a) =>
      (a[0] as JObject).native as Map<Object, _Entry>;
  Object? init(Vm vm, JThread t, List<Object?> a) {
    (a[0] as JObject).native = <Object, _Entry>{};
    return null;
  }

  n['$ht.<init>()V'] = init;
  n['$ht.<init>(I)V'] = init;
  n['$ht.put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;'] =
      (vm, t, a) {
    if (a[2] == null) throw JavaThrow('java/lang/NullPointerException');
    final tb = table(a);
    final key = _hkey(a[1]);
    final old = tb[key];
    if (old != null) {
      final prev = old.value;
      old.value = a[2];
      return prev;
    }
    tb[key] = _Entry(a[1], a[2]);
    return null;
  };
  n['$ht.get(Ljava/lang/Object;)Ljava/lang/Object;'] =
      (vm, t, a) => table(a)[_hkey(a[1])]?.value;
  n['$ht.remove(Ljava/lang/Object;)Ljava/lang/Object;'] =
      (vm, t, a) => table(a).remove(_hkey(a[1]))?.value;
  n['$ht.containsKey(Ljava/lang/Object;)Z'] =
      (vm, t, a) => table(a).containsKey(_hkey(a[1])) ? 1 : 0;
  n['$ht.contains(Ljava/lang/Object;)Z'] = (vm, t, a) {
    for (final e in table(a).values) {
      if (vm.javaEquals(e.value, a[1])) return 1;
    }
    return 0;
  };
  n['$ht.size()I'] = (vm, t, a) => table(a).length;
  n['$ht.isEmpty()Z'] = (vm, t, a) => table(a).isEmpty ? 1 : 0;
  n['$ht.clear()V'] = (vm, t, a) {
    table(a).clear();
    return null;
  };
  n['$ht.keys()Ljava/util/Enumeration;'] =
      (vm, t, a) => makeEnum([for (final e in table(a).values) e.key]);
  n['$ht.elements()Ljava/util/Enumeration;'] =
      (vm, t, a) => makeEnum([for (final e in table(a).values) e.value]);
}

// ------------------------------------------- javax.microedition.media (audio)

void _media(Vm vm, {required int audioVolume}) {
  final n = vm.natives;

  const m = 'javax/microedition/media/';
  const mc = 'javax/microedition/media/control/';

  vm.defineClass('${m}MediaException', 'java/lang/Exception');

  vm.defineClass(
    '${m}Control',
    'java/lang/Object',
    iface: true,
  );

  vm.defineClass(
    '${mc}VolumeControl',
    'java/lang/Object',
    interfaces: ['${m}Control'],
    iface: true,
  );

  vm.defineClass(
    '${mc}ToneControl',
    'java/lang/Object',
    interfaces: ['${m}Control'],
    iface: true,
  );

  vm.defineClass(
    '${m}PlayerListener',
    'java/lang/Object',
    iface: true,
  );

  vm.defineClass(
    '${m}Controllable',
    'java/lang/Object',
    iface: true,
  );

  vm.defineClass(
    '${m}Player',
    'java/lang/Object',
    interfaces: ['${m}Controllable'],
    iface: true,
  );

  vm.defineClass(
    '${m}Manager',
    'java/lang/Object',
  );

  vm.defineClass(
    '${m}NativeVolume',
    'java/lang/Object',
    interfaces: ['${mc}VolumeControl'],
  );

  vm.defineClass(
    '${m}NativeToneControl',
    'java/lang/Object',
    interfaces: ['${mc}ToneControl'],
  );

  vm.defineClass(
    '${m}NativePlayer',
    'java/lang/Object',
    interfaces: ['${m}Player'],
  );

  vm.classes['${m}Player']!.statics.addAll(const {
    'CLOSED': 0,
    'UNREALIZED': 100,
    'REALIZED': 200,
    'PREFETCHED': 300,
    'STARTED': 400,
    'TIME_UNKNOWN': -1,
  });

  vm.classes['${mc}ToneControl']!.statics.addAll(const {
    'VERSION': -2,
    'TEMPO': -3,
    'RESOLUTION': -4,
    'BLOCK_START': -5,
    'BLOCK_END': -6,
    'PLAY_BLOCK': -7,
    'SET_VOLUME': -8,
    'REPEAT': -9,
    'SILENCE': -1,
    'C4': 60,
  });

  // Noms des événements envoyés à PlayerListener.playerUpdate().
  vm.classes['${m}PlayerListener']!.statics.addAll({
    'STARTED': vm.intern('started'),
    'STOPPED': vm.intern('stopped'),
    'STOPPED_AT_TIME': vm.intern('stoppedAtTime'),
    'END_OF_MEDIA': vm.intern('endOfMedia'),
    'DURATION_UPDATED': vm.intern('durationUpdated'),
    'DEVICE_UNAVAILABLE': vm.intern('deviceUnavailable'),
    'DEVICE_AVAILABLE': vm.intern('deviceAvailable'),
    'VOLUME_CHANGED': vm.intern('volumeChanged'),
    'ERROR': vm.intern('error'),
    'CLOSED': vm.intern('closed'),
  });

  vm.classes['${m}Manager']!.statics.addAll({
    'TONE_DEVICE_LOCATOR': vm.intern('device://tone'),
    'MIDI_DEVICE_LOCATOR': vm.intern('device://midi'),
  });

  final engine = AudioEngine(initialVolume: audioVolume, onDiagnostic: vm.log);

  final playerCls = vm.classes['${m}NativePlayer']!;
  final volumeCls = vm.classes['${m}NativeVolume']!;
  final toneControlCls = vm.classes['${m}NativeToneControl']!;

  final players = <int, JObject>{};

  /// Lance une opération audio sans attendre, en journalisant l'erreur au lieu
  /// de laisser une exception asynchrone non rattrapée.
  void fire(Future<dynamic> f) {
    f.then<void>(
      (_) {},
      onError: (Object e) => vm.log('Audio : $e'),
    );
  }

  /// Envoie playerUpdate(player, événement, null) au PlayerListener du jeu,
  /// dans un thread Java séparé (comme sur un vrai téléphone).
  void notify(JObject player, String event) {
    final listener = (player.native as _PlayerState).listener;
    if (listener == null) return;
    final method = vm.findMethod(
      listener.cls,
      'playerUpdate',
      '(L${m}Player;Ljava/lang/String;Ljava/lang/Object;)V',
    );
    if (method == null || method.native != null) return;
    vm.spawn('audio-event', method, [listener, player, vm.intern(event), null]);
  }

  JObject createPlayer({
    Uint8List? data,
    String? mimeType,
    String sourceDescription = 'InputStream',
    bool isDeviceLocator = false,
  }) {
    final audioId = engine.createPlayer(
      data: data,
      mimeType: mimeType,
      sourceDescription: sourceDescription,
    );

    final object = JObject(playerCls);

    final state = _PlayerState(audioId,
        sourceDescription: sourceDescription, isDeviceLocator: isDeviceLocator);

    object.native = state;

    players[audioId] = object;

    engine.onComplete(audioId).listen((_) {
      if (state.state == 400) {
        state.state = 300;
        notify(object, 'endOfMedia');
      }
    }, onError: (Object error) {
      // Platform audio failures arrive on audioplayers' event stream as well
      // as through play(). Consume them here so invalid sources cannot become
      // uncaught Dart zone errors.
      vm.log('Audio : erreur du lecteur ${state.sourceDescription} : $error');
    });

    return object;
  }

  JObject volumeFor(_PlayerState state) =>
      JObject(volumeCls)..native = _VolumeState(engine, state.audioId);

  JObject toneControlFor(_PlayerState state) =>
      JObject(toneControlCls)..native = _ToneControlState(engine, state);

  _PlayerState ps(List<Object?> a) {
    return (a[0] as JObject).native as _PlayerState;
  }

  // ------------------------------------------------------------
  // Manager.createPlayer(InputStream, String)
  // ------------------------------------------------------------

  n['${m}Manager.createPlayer(Ljava/io/InputStream;Ljava/lang/String;)L${m}Player;'] =
      (vm, t, a) {
    // Manager.createPlayer est statique : aucun récepteur en a[0].
    final stream = a[0];

    if (stream is! JObject) {
      final caller = t.frames.isEmpty
          ? 'appel inconnu'
          : '${t.frames.last.method.owner.name}.${t.frames.last.method.name}${t.frames.last.method.desc}';
      vm.log('Audio : Manager.createPlayer a reçu un InputStream nul/invalide depuis $caller.');
      return createPlayer(sourceDescription: 'InputStream nul (appelé depuis $caller)');
    }

    final native = stream.native;

    if (native is _In) {
      final typeObject = a[1];

      String? type;

      if (typeObject is String) {
        type = typeObject;
      }

      if (native.data.isEmpty) {
        vm.log(
            'Audio : Manager.createPlayer a reçu un InputStream vide (type ${type ?? 'inconnu'}).');
      }

      return createPlayer(
        data: Uint8List.fromList(native.data),
        mimeType: type,
        sourceDescription: 'InputStream (${native.data.length} octets)',
      );
    }

    vm.log('Audio : InputStream natif non pris en charge (${native.runtimeType}).');
    return createPlayer(
      sourceDescription: 'InputStream natif non pris en charge (${native.runtimeType})',
    );
  };

  // ------------------------------------------------------------
  // Manager.createPlayer(String locator)
  // ------------------------------------------------------------

  n['${m}Manager.createPlayer(Ljava/lang/String;)L${m}Player;'] = (vm, t, a) {
    // Méthode statique : locator est le premier argument.
    final locator = a[0];

    if (locator is String) {
      if (locator.startsWith('device://')) {
        return createPlayer(
          sourceDescription: locator,
          isDeviceLocator: true,
        );
      }

      var key = locator;
      if (locator.startsWith('resource://')) {
        final uri = Uri.parse(locator);
        key = '${uri.host}${uri.path}';
      } else if (locator.startsWith('classpath:')) {
        key = locator.substring('classpath:'.length);
      } else if (locator.startsWith('file://')) {
        key = Uri.parse(locator).path;
      }
      key = _normalizeJarPath(key);
      final actualKey = _jarResourceKey(vm.jar.files, key);
      final bytes = actualKey == null ? null : vm.jar.files[actualKey];

      if (bytes != null) {
        final extension = actualKey!.split('.').last.toLowerCase();
        final mimeType = switch (extension) {
          'wav' => 'audio/wav',
          'mp3' => 'audio/mpeg',
          'm4a' || 'mp4' || 'aac' => 'audio/mp4',
          'ogg' || 'oga' => 'audio/ogg',
          'mid' || 'midi' => 'audio/midi',
          'amr' => 'audio/amr',
          '3gp' => 'audio/3gpp',
          _ => null,
        };
        return createPlayer(
          data: bytes,
          mimeType: mimeType,
          sourceDescription: '$locator → $actualKey (${bytes.length} octets)',
        );
      }
      final audioCandidates = vm.jar.files.keys
          .where((name) => RegExp(r'\.(wav|mp3|m4a|aac|ogg|amr|mid|midi|3gp)$',
                  caseSensitive: false)
              .hasMatch(name))
          .take(8)
          .join(', ');
      vm.log(
          'Audio : ressource introuvable pour Manager.createPlayer("$locator") (clé JAR "$key").'
          '${audioCandidates.isEmpty ? '' : ' Ressources audio présentes : $audioCandidates'}');
    } else {
      vm.log('Audio : locator invalide pour Manager.createPlayer : $locator');
    }

    return createPlayer(sourceDescription: 'ressource introuvable : $locator');
  };

  // ------------------------------------------------------------
  // Manager.playTone(int frequency, int duration, int volume)
  // ------------------------------------------------------------

  n['${m}Manager.playTone(III)V'] = (vm, t, a) {
    // Méthode statique : frequency, duration et volume commencent en a[0].
    final frequency = (a[0] as num).toInt();
    final duration = (a[1] as num).toInt();
    final volume = (a[2] as num).toInt();

    _playTone(
      engine,
      frequency,
      duration,
      volume,
    );

    return null;
  };

  // ------------------------------------------------------------
  // Player
  // ------------------------------------------------------------

  const p = '${m}NativePlayer';

  n['$p.realize()V'] = (vm, t, a) {
    final state = ps(a);

    if (state.state == 0) return null;

    if (state.state < 200) state.state = 200;

    return null;
  };

  n['$p.prefetch()V'] = (vm, t, a) {
    final state = ps(a);

    if (state.state == 0) return null;

    if (state.state < 300) state.state = 300;

    return null;
  };

  n['$p.start()V'] = (vm, t, a) {
    final state = ps(a);

    if (state.state == 0) return null;

    if (state.isDeviceLocator) {
      final wasStarted = state.state == 400;
      state.state = 400;
      if (state.toneSequenceSet) {
        fire(engine.start(state.audioId));
      } else if (!state.warnedAboutUnsupportedDevice) {
        state.warnedAboutUnsupportedDevice = true;
        vm.log(
            'Audio : ${state.sourceDescription} ne fournit pas de flux audio; seul device://tone avec ToneControl est pris en charge.');
      }
      if (!wasStarted) notify(a[0] as JObject, 'started');
      return null;
    }

    final wasStarted = state.state == 400;

    state.state = 400;

    fire(engine.start(state.audioId));

    if (!wasStarted) notify(a[0] as JObject, 'started');

    return null;
  };

  n['$p.stop()V'] = (vm, t, a) {
    final state = ps(a);

    if (state.state == 0) return null;

    final wasStarted = state.state == 400;

    fire(engine.stop(state.audioId));

    state.state = 300;

    if (wasStarted) notify(a[0] as JObject, 'stopped');

    return null;
  };

  n['$p.deallocate()V'] = (vm, t, a) {
    final state = ps(a);

    if (state.state == 0) return null;

    fire(engine.stop(state.audioId));

    state.state = 200;

    return null;
  };

  n['$p.close()V'] = (vm, t, a) {
    final state = ps(a);

    if (state.state == 0) return null;

    fire(engine.close(state.audioId));

    state.state = 0;

    players.remove(state.audioId);

    notify(a[0] as JObject, 'closed');

    return null;
  };

  n['$p.getState()I'] = (vm, t, a) {
    return ps(a).state;
  };

  n['$p.setLoopCount(I)V'] = (vm, t, a) {
    final state = ps(a);
    final count = (a[1] as num).toInt();

    state.loopCount = count;

    fire(
      engine.setLoopCount(
        state.audioId,
        count,
      ),
    );

    return null;
  };

  // Durée inconnue (TIME_UNKNOWN = -1) : on ne la lit pas dans le moteur audio.
  n['$p.getDuration()J'] = (vm, t, a) => -1;

  // L'API Java compte le temps en MICROsecondes.
  n['$p.getMediaTime()J'] = (vm, t, a) {
    return ps(a).mediaTimeMs * 1000;
  };

  n['$p.setMediaTime(J)J'] = (vm, t, a) {
    final state = ps(a);

    final micros = (a[1] as num).toInt();

    state.mediaTimeMs = micros ~/ 1000;

    fire(
      engine.setPosition(
        state.audioId,
        Duration(microseconds: micros),
      ),
    );

    return micros;
  };

  n['$p.addPlayerListener(L${m}PlayerListener;)V'] = (vm, t, a) {
    final state = ps(a);

    final listener = a[1];

    if (listener is JObject) {
      state.listener = listener;
    }

    return null;
  };

  n['$p.removePlayerListener(L${m}PlayerListener;)V'] = (vm, t, a) {
    final state = ps(a);

    state.listener = null;

    return null;
  };

  // ------------------------------------------------------------
  // Controls
  // ------------------------------------------------------------

  // getControl("VolumeControl") ou "javax.microedition.media.control.VolumeControl".
  // Les autres contrôles n'existent pas ici : null, comme le prévoit l'API.
  n['$p.getControl(Ljava/lang/String;)L${m}Control;'] = (vm, t, a) {
    final name = a[1];

    if (name is! String) {
      throw JavaThrow('java/lang/IllegalArgumentException');
    }

    final state = ps(a);
    if (name.endsWith('VolumeControl')) return volumeFor(state);
    if (name.endsWith('ToneControl') &&
        state.isDeviceLocator &&
        state.sourceDescription == 'device://tone') {
      return toneControlFor(state);
    }
    return null;
  };

  n['$p.getControls()[L${m}Control;'] = (vm, t, a) {
    final state = ps(a);
    final controls = <Object?>[volumeFor(state)];
    if (state.isDeviceLocator && state.sourceDescription == 'device://tone') {
      controls.add(toneControlFor(state));
    }
    return JArray(
      '[L${m}Control;',
      controls,
    );
  };

  const v = '${m}NativeVolume';

  n['$v.setLevel(I)I'] = (vm, t, a) {
    final volume = (a[0] as JObject).native as _VolumeState;
    final level = (a[1] as num).toInt().clamp(0, 100);

    fire(
      volume.engine.setVolume(
        volume.audioId,
        level,
      ),
    );

    return level;
  };

  n['$v.getLevel()I'] = (vm, t, a) {
    final volume = (a[0] as JObject).native as _VolumeState;

    return volume.engine.getVolume(
      volume.audioId,
    );
  };

  n['$v.setMute(Z)V'] = (vm, t, a) {
    final volume = (a[0] as JObject).native as _VolumeState;
    final muted = (a[1] as num).toInt() != 0;

    fire(
      volume.engine.setMute(
        volume.audioId,
        muted,
      ),
    );

    return null;
  };

  n['$v.isMuted()Z'] = (vm, t, a) {
    final volume = (a[0] as JObject).native as _VolumeState;

    return volume.engine.isMuted(
      volume.audioId,
    )
        ? 1
        : 0;
  };

  const tc = '${m}NativeToneControl';
  n['$tc.setSequence([B)V'] = (vm, t, a) {
    final control = (a[0] as JObject).native as _ToneControlState;
    final player = control.player;
    if (player.state >= 300) {
      throw JavaThrow('java/lang/IllegalStateException');
    }
    final sequence = _i8(a[1]);
    if (sequence.isEmpty) {
      throw JavaThrow('java/lang/IllegalArgumentException');
    }
    try {
      final wav = _toneSequenceWav(sequence);
      control.engine.updateSource(player.audioId, wav, mimeType: 'audio/wav');
      player.toneSequenceSet = true;
    } on FormatException catch (e) {
      throw JavaThrow('java/lang/IllegalArgumentException', e.message);
    }
    return null;
  };
}

class _VolumeState {
  final AudioEngine engine;
  final int audioId;

  _VolumeState(
    this.engine,
    this.audioId,
  );
}

class _ToneControlState {
  const _ToneControlState(this.engine, this.player);
  final AudioEngine engine;
  final _PlayerState player;
}

// ------------------------------------------------------- classes Nokia

void _nokia(Vm vm) {
  final n = vm.natives;
  // Beaucoup de jeux Series 40 héritent de FullCanvas au lieu de Canvas.
  vm.defineClass(
      'com/nokia/mid/ui/FullCanvas', 'javax/microedition/lcdui/Canvas');
  vm.classes['com/nokia/mid/ui/FullCanvas']!.statics.addAll(const {
    'KEY_UP_ARROW': -1,
    'KEY_DOWN_ARROW': -2,
    'KEY_LEFT_ARROW': -3,
    'KEY_RIGHT_ARROW': -4,
    'KEY_SOFTKEY1': -6,
    'KEY_SOFTKEY2': -7,
    'KEY_SOFTKEY3': -5,
    'KEY_SEND': -10,
    'KEY_END': -11,
  });

  vm.defineClass('com/nokia/mid/ui/DeviceControl', 'java/lang/Object');
  const dc = 'com/nokia/mid/ui/DeviceControl';
  n['$dc.setLights(II)V'] = (vm, t, a) => null;
  n['$dc.flashLights(J)V'] = (vm, t, a) => null;
  n['$dc.startVibra(IJ)V'] = (vm, t, a) => null;
  n['$dc.stopVibra()V'] = (vm, t, a) => null;
}

void _playTone(
  AudioEngine engine,
  int frequency,
  int durationMs,
  int volume,
) {
  if (frequency <= 0 || durationMs <= 0) {
    return;
  }

  final wav = _generateToneWav(
    frequency,
    durationMs,
    volume,
  );

  final id = engine.createPlayer(
    data: wav,
    mimeType: 'audio/wav',
    sourceDescription: 'Manager.playTone ($frequency Hz, $durationMs ms)',
  );

  unawaited(
    engine.start(id).then(
          (_) => Future.delayed(
            Duration(milliseconds: durationMs + 100),
            () => engine.close(id),
          ),
        ),
  );
}

Uint8List _generateToneWav(
  int frequency,
  int durationMs,
  int volume,
) {
  const sampleRate = 44100;
  const channels = 1;
  const bitsPerSample = 16;

  final sampleCount = (sampleRate * durationMs / 1000).round();

  final dataSize = sampleCount * 2;
  final buffer = ByteData(44 + dataSize);

  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      buffer.setUint8(
        offset + i,
        value.codeUnitAt(i),
      );
    }
  }

  writeAscii(0, 'RIFF');
  buffer.setUint32(
    4,
    36 + dataSize,
    Endian.little,
  );

  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');

  buffer.setUint32(
    16,
    16,
    Endian.little,
  );

  buffer.setUint16(
    20,
    1,
    Endian.little,
  );

  buffer.setUint16(
    22,
    channels,
    Endian.little,
  );

  buffer.setUint32(
    24,
    sampleRate,
    Endian.little,
  );

  buffer.setUint32(
    28,
    sampleRate * channels * bitsPerSample ~/ 8,
    Endian.little,
  );

  buffer.setUint16(
    32,
    channels * bitsPerSample ~/ 8,
    Endian.little,
  );

  buffer.setUint16(
    34,
    bitsPerSample,
    Endian.little,
  );

  writeAscii(36, 'data');

  buffer.setUint32(
    40,
    dataSize,
    Endian.little,
  );

  final amplitude = 32767 * (volume.clamp(0, 100) / 100.0);

  for (var i = 0; i < sampleCount; i++) {
    final t = i / sampleRate;

    final sample = (math.sin(2 * math.pi * frequency * t) * amplitude).round();

    buffer.setInt16(
      44 + i * 2,
      sample,
      Endian.little,
    );
  }

  return buffer.buffer.asUint8List();
}

class _ToneSegment {
  const _ToneSegment(this.note, this.durationMs, this.volume);
  final int note;
  final int durationMs;
  final int volume;
}

/// Convertit le format ToneControl v1 en PCM WAV pour le moteur audio natif.
Uint8List _toneSequenceWav(Int8List sequence) {
  if (sequence.length < 4 || sequence[0] != -2 || sequence[1] != 1) {
    throw const FormatException('séquence ToneControl sans VERSION 1');
  }

  var tempoModifier = 30; // 120 BPM
  var resolution = 64;
  var volume = 100;
  var index = 2;
  final segments = <_ToneSegment>[];
  final blocks = <int, List<_ToneSegment>>{};

  int parameter(String name, {required int min, required int max}) {
    if (index >= sequence.length) {
      throw FormatException('paramètre $name manquant');
    }
    final value = sequence[index++];
    if (value < min || value > max) {
      throw FormatException('$name hors limites : $value');
    }
    return value;
  }

  void addNote(int note) {
    if (note < -1 || note > 127) {
      throw FormatException('note invalide : $note');
    }
    final durationTicks = parameter('durée', min: 1, max: 127);
    final durationMs =
        (durationTicks * 60000 / (resolution * tempoModifier)).round();
    segments.add(_ToneSegment(note, durationMs, volume));
  }

  void addBlock(int blockNumber) {
    final block = blocks[blockNumber];
    if (block == null) {
      throw FormatException('bloc ToneControl $blockNumber non défini');
    }
    segments.addAll(block);
  }

  void parseEvents({int? expectedBlock}) {
    while (index < sequence.length) {
      final tag = sequence[index++];
      if (tag == -6) {
        if (expectedBlock == null) {
          throw const FormatException('BLOCK_END sans BLOCK_START');
        }
        final endBlock = parameter('numéro de fin de bloc', min: 0, max: 127);
        if (endBlock != expectedBlock) {
          throw FormatException(
              'BLOCK_END $endBlock ne correspond pas à $expectedBlock');
        }
        return;
      }
      switch (tag) {
        case -3: // TEMPO: modifier × 4 = BPM
          tempoModifier = parameter('tempo', min: 5, max: 127);
        case -4: // RESOLUTION
          resolution = parameter('résolution', min: 1, max: 127);
        case -8: // SET_VOLUME
          volume = parameter('volume', min: 0, max: 100);
        case -9: // REPEAT a tone event
          final count = parameter('répétition', min: 2, max: 127);
          if (index >= sequence.length) {
            throw const FormatException('note répétée absente');
          }
          final repeatedTag = sequence[index++];
          List<_ToneSegment> repeated;
          if (repeatedTag == -7) {
            repeated = blocks[parameter('bloc', min: 0, max: 127)] ??
                (throw const FormatException('bloc REPEAT non défini'));
          } else if (repeatedTag == -1 ||
              (repeatedTag >= 0 && repeatedTag <= 127)) {
            final before = segments.length;
            addNote(repeatedTag);
            repeated = [segments.removeLast()];
            if (segments.length != before) {
              throw const FormatException('événement REPEAT invalide');
            }
          } else {
            throw FormatException('événement REPEAT invalide : $repeatedTag');
          }
          segments.addAll(repeated);
          for (var i = 1; i < count; i++) {
            segments.addAll(repeated);
          }
        case -5: // BLOCK_START
          final blockNumber = parameter('numéro de bloc', min: 0, max: 127);
          final before = segments.length;
          parseEvents(expectedBlock: blockNumber);
          blocks[blockNumber] = segments.sublist(before);
          segments.removeRange(before, segments.length);
        case -7: // PLAY_BLOCK
          addBlock(parameter('bloc', min: 0, max: 127));
        case -1:
        case >= 0 && <= 127:
          addNote(tag);
        default:
          throw FormatException(
              'commande ToneControl non prise en charge : $tag');
      }
    }
    if (expectedBlock != null) {
      throw const FormatException('BLOCK_END manquant');
    }
  }

  parseEvents();

  if (segments.isEmpty) {
    throw const FormatException('séquence ToneControl vide');
  }
  const sampleRate = 22050;
  const maxSamples = sampleRate * 180;
  final counts = [
    for (final segment in segments)
      (sampleRate * segment.durationMs / 1000).round()
  ];
  final sampleCount = counts.fold<int>(0, (total, count) => total + count);
  if (sampleCount <= 0 || sampleCount > maxSamples) {
    throw const FormatException('durée totale ToneControl hors limites');
  }

  final dataSize = sampleCount * 2;
  final buffer = ByteData(44 + dataSize);
  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      buffer.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  buffer.setUint32(4, 36 + dataSize, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  buffer.setUint32(16, 16, Endian.little);
  buffer.setUint16(20, 1, Endian.little);
  buffer.setUint16(22, 1, Endian.little);
  buffer.setUint32(24, sampleRate, Endian.little);
  buffer.setUint32(28, sampleRate * 2, Endian.little);
  buffer.setUint16(32, 2, Endian.little);
  buffer.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  buffer.setUint32(40, dataSize, Endian.little);

  var outputIndex = 0;
  for (var s = 0; s < segments.length; s++) {
    final segment = segments[s];
    final count = counts[s];
    final frequency =
        segment.note < 0 ? 0.0 : 440 * math.pow(2, (segment.note - 69) / 12);
    final maxAmplitude = 10000 * segment.volume / 100;
    final fadeSamples = math.min(110, count ~/ 2);
    for (var i = 0; i < count; i++) {
      var envelope = 1.0;
      if (fadeSamples > 0 && i < fadeSamples) envelope = i / fadeSamples;
      if (fadeSamples > 0 && count - i - 1 < fadeSamples) {
        envelope = math.min(envelope, (count - i - 1) / fadeSamples);
      }
      final sample = frequency == 0
          ? 0
          : (math.sin(2 * math.pi * frequency * i / sampleRate) *
                  maxAmplitude *
                  envelope)
              .round();
      buffer.setInt16(44 + outputIndex * 2, sample, Endian.little);
      outputIndex++;
    }
  }
  return buffer.buffer.asUint8List();
}

// ---------------------------------------------- String et StringBuffer (suite)

String _sarg(List<Object?> a, int i) {
  final v = a[i];
  if (v == null) throw JavaThrow('java/lang/NullPointerException');
  return v as String;
}

bool _isLatin(String e) =>
    e.contains('8859') || e.contains('LATIN') || e.contains('ASCII');

String _normEnc(String? enc) =>
    (enc ?? 'UTF-8').toUpperCase().replaceAll('_', '-');

/// Octets -> chaîne selon l'encodage Java demandé (UTF-8 par défaut).
String _decodeBytes(Int8List b, int off, int len, String? enc) {
  if (off < 0 || len < 0 || off + len > b.length) {
    throw JavaThrow('java/lang/StringIndexOutOfBoundsException');
  }
  final bytes = Uint8List(len);
  for (var i = 0; i < len; i++) {
    bytes[i] = b[off + i];
  }
  final e = _normEnc(enc);
  if (_isLatin(e)) return latin1.decode(bytes, allowInvalid: true);
  if (e.startsWith('UTF-16')) {
    var i = 0;
    var le = e.endsWith('LE');
    if (len >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      i = 2;
      le = false;
    } else if (len >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      i = 2;
      le = true;
    }
    final units = <int>[];
    for (; i + 1 < len; i += 2) {
      units.add(
          le ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Chaîne -> octets selon l'encodage Java demandé (UTF-8 par défaut).
List<int> _encodeString(String s, String? enc) {
  final e = _normEnc(enc);
  if (_isLatin(e)) return [for (final c in s.codeUnits) c < 256 ? c : 63];
  if (e.startsWith('UTF-16')) {
    final le = e.endsWith('LE');
    final out = <int>[];
    if (e == 'UTF-16') out.addAll(const [0xFE, 0xFF]);
    for (final c in s.codeUnits) {
      if (le) {
        out
          ..add(c & 0xFF)
          ..add(c >> 8);
      } else {
        out
          ..add(c >> 8)
          ..add(c & 0xFF);
      }
    }
    return out;
  }
  return utf8.encode(s);
}

void _stringMore(Vm vm) {
  final n = vm.natives;
  void add(String key, NativeFn f) => n.putIfAbsent(key, () => f);
  const c = 'java/lang/String';

  // new String(bytes, offset, length, encoding) : utilisé par la plupart des
  // jeux pour lire leurs textes dans un fichier de ressources.
  n['$c.<init>([BIILjava/lang/String;)V'] = (vm, t, a) =>
      _decodeBytes(_i8(a[1]), a[2] as int, a[3] as int, a[4] as String?);
  n['$c.<init>([BLjava/lang/String;)V'] = (vm, t, a) {
    final b = _i8(a[1]);
    return _decodeBytes(b, 0, b.length, a[2] as String?);
  };
  n['$c.getBytes(Ljava/lang/String;)[B'] = (vm, t, a) => JArray(
      '[B', Int8List.fromList(_encodeString(a[0] as String, a[1] as String?)));

  add('$c.lastIndexOf(II)I', (vm, t, a) {
    final s = a[0] as String;
    final from = a[2] as int;
    if (from < 0) return -1;
    return s.lastIndexOf(
        String.fromCharCode(a[1] as int), math.min(from, s.length));
  });
  add('$c.lastIndexOf(Ljava/lang/String;)I',
      (vm, t, a) => (a[0] as String).lastIndexOf(_sarg(a, 1)));
  add('$c.lastIndexOf(Ljava/lang/String;I)I', (vm, t, a) {
    final s = a[0] as String;
    final from = a[2] as int;
    if (from < 0) return -1;
    return s.lastIndexOf(_sarg(a, 1), math.min(from, s.length));
  });
  add(
      '$c.replace(CC)Ljava/lang/String;',
      (vm, t, a) => (a[0] as String).replaceAll(
          String.fromCharCode(a[1] as int), String.fromCharCode(a[2] as int)));
  add('$c.startsWith(Ljava/lang/String;I)Z', (vm, t, a) {
    final s = a[0] as String;
    final off = a[2] as int;
    if (off < 0 || off > s.length) return 0;
    return s.startsWith(_sarg(a, 1), off) ? 1 : 0;
  });
  add('$c.intern()Ljava/lang/String;', (vm, t, a) => vm.intern(a[0] as String));

  // StringBuffer : le texte vit dans un StringBuffer Dart (écriture seule),
  // donc on réécrit le contenu complet pour les modifications au milieu.
  const sbn = 'java/lang/StringBuffer';
  StringBuffer buf(List<Object?> a) => (a[0] as JObject).native as StringBuffer;
  void setText(List<Object?> a, String text) {
    final b = buf(a);
    b.clear();
    b.write(text);
  }

  Object? insertAt(List<Object?> a, String piece) {
    final s = buf(a).toString();
    final i = a[1] as int;
    if (i < 0 || i > s.length) {
      throw JavaThrow('java/lang/StringIndexOutOfBoundsException', '$i');
    }
    setText(a, s.substring(0, i) + piece + s.substring(i));
    return a[0];
  }

  add('$sbn.setCharAt(IC)V', (vm, t, a) {
    final s = buf(a).toString();
    final i = a[1] as int;
    if (i < 0 || i >= s.length) {
      throw JavaThrow('java/lang/StringIndexOutOfBoundsException', '$i');
    }
    setText(
        a,
        s.substring(0, i) +
            String.fromCharCode(a[2] as int) +
            s.substring(i + 1));
    return null;
  });
  add('$sbn.deleteCharAt(I)Ljava/lang/StringBuffer;', (vm, t, a) {
    final s = buf(a).toString();
    final i = a[1] as int;
    if (i < 0 || i >= s.length) {
      throw JavaThrow('java/lang/StringIndexOutOfBoundsException', '$i');
    }
    setText(a, s.substring(0, i) + s.substring(i + 1));
    return a[0];
  });
  add('$sbn.delete(II)Ljava/lang/StringBuffer;', (vm, t, a) {
    final s = buf(a).toString();
    final start = a[1] as int;
    final end = math.min(a[2] as int, s.length);
    if (start < 0 || start > end) {
      throw JavaThrow('java/lang/StringIndexOutOfBoundsException', '$start');
    }
    setText(a, s.substring(0, start) + s.substring(end));
    return a[0];
  });
  add('$sbn.insert(IC)Ljava/lang/StringBuffer;',
      (vm, t, a) => insertAt(a, String.fromCharCode(a[2] as int)));
  add('$sbn.insert(II)Ljava/lang/StringBuffer;',
      (vm, t, a) => insertAt(a, '${a[2]}'));
  add('$sbn.insert(ILjava/lang/Object;)Ljava/lang/StringBuffer;',
      (vm, t, a) => insertAt(a, vm.str(a[2])));
  add('$sbn.capacity()I', (vm, t, a) => math.max(16, buf(a).length));
  add('$sbn.ensureCapacity(I)V', (vm, t, a) => null);
}

// ------------------------------------------------------------ Integer (suite)

void _integerMore(Vm vm) {
  final n = vm.natives;
  const c = 'java/lang/Integer';
  final intClass = vm.classes[c]!;
  void add(String key, NativeFn f) => n.putIfAbsent(key, () => f);

  int parse(Object? v, int radix) {
    if (v == null) throw JavaThrow('java/lang/NumberFormatException', 'null');
    final str = v as String;
    final r = int.tryParse(
      str.startsWith('+') ? str.substring(1) : str,
      radix: radix,
    );
    if (r == null || r > 2147483647 || r < -2147483648) {
      throw JavaThrow('java/lang/NumberFormatException', str);
    }
    return r;
  }

  int value(List<Object?> a) => (a[0] as JObject).native as int;
  double toFloat(num x) {
    final f = Float32List(1);
    f[0] = x.toDouble();
    return f[0];
  }

  // Integer.valueOf("42") : très utilisé pour lire des nombres dans des textes.
  add('$c.valueOf(Ljava/lang/String;)Ljava/lang/Integer;',
      (vm, t, a) => JObject(intClass)..native = parse(a[0], 10));
  add('$c.valueOf(Ljava/lang/String;I)Ljava/lang/Integer;',
      (vm, t, a) => JObject(intClass)..native = parse(a[0], a[1] as int));
  add('$c.toString(II)Ljava/lang/String;',
      (vm, t, a) => (a[0] as int).toRadixString(a[1] as int));
  add('$c.toBinaryString(I)Ljava/lang/String;',
      (vm, t, a) => ((a[0] as int) & 0xFFFFFFFF).toRadixString(2));
  add('$c.toOctalString(I)Ljava/lang/String;',
      (vm, t, a) => ((a[0] as int) & 0xFFFFFFFF).toRadixString(8));
  add('$c.byteValue()B', (vm, t, a) => value(a).toSigned(8));
  add('$c.shortValue()S', (vm, t, a) => value(a).toSigned(16));
  add('$c.longValue()J', (vm, t, a) => value(a));
  add('$c.floatValue()F', (vm, t, a) => toFloat(value(a)));
  add('$c.doubleValue()D', (vm, t, a) => value(a).toDouble());
}
