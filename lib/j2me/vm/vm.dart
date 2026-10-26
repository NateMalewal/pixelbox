import 'dart:typed_data';

import '../class_parser.dart';
import '../jar_loader.dart';
import 'runtime.dart';

export 'runtime.dart';

/// Référence de méthode résolue (cache par index du constant pool).
class MRef {
  MRef(this.cls, this.name, this.desc) : sig = Sig.of(desc);

  final JClass cls;
  final String name;
  final String desc;
  final Sig sig;
  JMethod? direct;
}

/// Référence de champ résolue.
class FRef {
  FRef(this.name, this.holder, this.wide);

  final String name;

  /// Pour les champs statiques : classe qui déclare le champ.
  final JClass? holder;

  /// true pour long et double (deux slots sur la pile).
  final bool wide;
}

final Float32List _f32buf = Float32List(1);

double f32(double x) {
  _f32buf[0] = x;
  return _f32buf[0];
}

int d2i(double d) {
  if (d.isNaN) return 0;
  if (d >= 2147483647.0) return 2147483647;
  if (d <= -2147483648.0) return -2147483648;
  return d.toInt();
}

int d2l(double d) {
  if (d.isNaN) return 0;
  if (d >= 9.223372036854775807e18) return 9223372036854775807;
  if (d <= -9.223372036854775808e18) return -9223372036854775808;
  return d.toInt();
}

int _i32(Uint8List c, int p) =>
    ((c[p] << 24) | (c[p + 1] << 16) | (c[p + 2] << 8) | c[p + 3]).toSigned(32);

class Vm {
  Vm(this.jar, this.log);

  final JarPackage jar;
  final void Function(String) log;

  final Map<String, JClass> classes = {};
  final Map<String, NativeFn> natives = {};
  final List<JThread> threads = [];
  final Map<String, String> _interned = {};
  final Stopwatch clock = Stopwatch()..start();

  int get nowMs => clock.elapsedMilliseconds;

  /// Appelé quand le MIDlet demande à quitter.
  void Function()? onExit;

  /// Appelé au début de chaque tick (file d'événements d'interface MIDP).
  void Function()? preTick;

  JClass get objectClass => classes['java/lang/Object']!;
  JClass get stringClass => classes['java/lang/String']!;

  String intern(String s) => _interned.putIfAbsent(s, () => s);

  // ---------------------------------------------------------------- classes

  JClass defineClass(
    String name,
    String? superName, {
    List<String> interfaces = const [],
    bool iface = false,
  }) {
    final c = JClass(
      name,
      null,
      superName == null ? null : classes[superName],
      [for (final i in interfaces) classes[i]!],
      builtinInterface: iface,
    );
    c.initialized = true;
    classes[name] = c;
    return c;
  }

  JClass? loadClass(String name) {
    final known = classes[name];
    if (known != null) return known;
    final bytes = jar.files['$name.class'];
    if (bytes == null) return null;

    final cf = ClassFile.parse(bytes);
    final sup = cf.superClass == null ? null : requireClass(cf.superClass!);
    final ifs = [for (final i in cf.interfaces) requireClass(i)];
    final c = JClass(name, cf, sup, ifs);

    for (final f in cf.fields) {
      if (!f.isStatic) continue;
      c.statics[f.name] = f.constantValueIndex != 0
          ? _constant(cf, f.constantValueIndex)
          : JClass.defaultFor(f.descriptor);
    }
    classes[name] = c;
    return c;
  }

  JClass requireClass(String name) {
    final c = loadClass(name);
    if (c == null) {
      log('Classe manquante : $name');
      throw JavaThrow('java/lang/NoClassDefFoundError', name);
    }
    return c;
  }

  Object? _constant(ClassFile cf, int idx) {
    final e = cf.constantPool[idx]!;
    if (e.tag == 8) return intern(cf.utf8At(e.a));
    return e.value;
  }

  JMethod? _declared(JClass k, String name, String desc) {
    final f = k.file;
    if (f != null) {
      final mi = f.findMethod(name, desc);
      if (mi != null && (mi.code != null || mi.isNative)) {
        return JMethod(
          k,
          name,
          desc,
          mi,
          mi.isNative ? natives['${k.name}.$name$desc'] : null,
        );
      }
      return null;
    }
    final nf = natives['${k.name}.$name$desc'];
    return nf == null ? null : JMethod(k, name, desc, null, nf);
  }

  JMethod? findMethod(JClass c, String name, String desc) {
    final key = '$name$desc';
    if (c.methodCache.containsKey(key)) return c.methodCache[key];
    JMethod? r;
    for (JClass? k = c; k != null && r == null; k = k.superClass) {
      r = _declared(k, name, desc);
    }
    if (r == null) {
      for (JClass? k = c; k != null && r == null; k = k.superClass) {
        for (final i in k.interfaces) {
          r ??= findMethod(i, name, desc);
        }
      }
    }
    return c.methodCache[key] = r;
  }

  JClass classOf(Object o) {
    if (o is String) return stringClass;
    if (o is JObject) return o.cls;
    return objectClass;
  }

  bool isInstance(Object? o, String name) {
    if (o == null) return false;
    if (name == 'java/lang/Object') return true;
    if (o is String) return name == 'java/lang/String';
    if (o is JObject) return o.cls.isSubclassOf(name);
    if (o is JArray) {
      return name.startsWith('[') &&
          (o.type == name || (o.type.startsWith('[L') && name.startsWith('[L')));
    }
    return false;
  }

  // ------------------------------------------------------------ utilitaires

  JObject makeThrowable(String clsName, String? msg) {
    JClass? c = classes[clsName];
    if (c == null) {
      try {
        c = loadClass(clsName);
      } catch (_) {}
    }
    c ??= classes['java/lang/Error']!;
    final o = JObject.withDefaults(c);
    o.fields['message'] = msg;
    return o;
  }

  /// Conversion en chaîne « à la Java » pour les natives.
  String str(Object? o) {
    if (o == null) return 'null';
    if (o is String) return o;
    if (o is JObject) {
      final n = o.native;
      if (n is StringBuffer) return n.toString();
      if (n is int && o.cls.name == 'java/lang/Integer') return n.toString();
      return '${o.cls.name.replaceAll('/', '.')}@${identityHashCode(o).toRadixString(16)}';
    }
    if (o is JArray) return '${o.type}@${identityHashCode(o).toRadixString(16)}';
    return o.toString();
  }

  bool javaEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is String && b is String) return a == b;
    if (a is JObject && b is JObject) {
      final x = a.native;
      final y = b.native;
      if (x is int && y is int && a.cls == b.cls) return x == y;
    }
    return false;
  }

  Frame newFrame(JMethod m, List<Object?> args) {
    final code = m.info?.code;
    if (code == null) {
      throw JavaThrow('java/lang/AbstractMethodError', '${m.owner.name}.${m.name}${m.desc}');
    }
    final lv = List<Object?>.filled(code.maxLocals + 1, null);
    var idx = 0;
    var ai = 0;
    if (!m.isStatic) {
      lv[idx++] = args[ai++];
    }
    for (final k in m.sig.args) {
      lv[idx] = args[ai++];
      idx += (k == 'J' || k == 'D') ? 2 : 1;
    }
    return Frame(m, lv, List<Object?>.filled(code.maxStack + 2, null));
  }

  /// Programme l'appel d'une méthode Java sur un thread (sera exécuté ensuite).
  void pushCall(JThread t, JMethod m, List<Object?> args) {
    t.frames.add(newFrame(m, args));
  }

  JThread spawn(String name, JMethod m, List<Object?> args) {
    final t = JThread(name);
    t.frames.add(newFrame(m, args));
    threads.add(t);
    return t;
  }

  /// Pousse les <clinit> nécessaires. Renvoie true si au moins un a été poussé
  /// (l'instruction courante doit alors être ré-exécutée après).
  bool ensureInit(JThread t, JClass c) {
    final pending = <JClass>[];
    for (JClass? k = c; k != null && !k.initialized; k = k.superClass) {
      k.initialized = true;
      final f = k.file;
      if (f != null && f.findMethod('<clinit>', '()V') != null) pending.add(k);
    }
    if (pending.isEmpty) return false;
    for (final k in pending) {
      final m = _declared(k, '<clinit>', '()V');
      if (m != null) t.frames.add(newFrame(m, const []));
    }
    return true;
  }

  /// Instancie le MIDlet et lance startApp() sur le thread principal.
  void startMidlet(String className) {
    final cls = requireClass(className);
    final obj = JObject.withDefaults(cls);
    final start = findMethod(cls, 'startApp', '()V');
    final ctor = findMethod(cls, '<init>', '()V');
    if (start == null || ctor == null) {
      log('MIDlet invalide : startApp() ou constructeur introuvable');
      return;
    }
    final t = JThread('main');
    t.frames.add(newFrame(start, [obj]));
    t.frames.add(newFrame(ctor, [obj]));
    ensureInit(t, cls);
    threads.add(t);
    log('MIDlet lancé : $className');
  }

  /// À appeler régulièrement (une fois par image environ).
  void tick({int budget = 300000}) {
    preTick?.call();
    final live = threads.where((t) => !t.done).toList();
    if (live.isEmpty) return;
    final now = nowMs;
    final per = budget ~/ live.length;
    for (final t in live) {
      if (t.wakeAt > now) continue;
      t.yielding = false;
      run(t, per);
    }
    threads.removeWhere((t) => t.done);
  }

  // ---------------------------------------------------------- résolutions

  MRef _methodRef(JClass owner, int idx) {
    return owner.rcache.putIfAbsent(idx, () {
      final cf = owner.file!;
      final e = cf.constantPool[idx]!;
      final nt = cf.constantPool[e.b]!;
      final cname = cf.classNameAt(e.a);
      final cls = cname.startsWith('[') ? objectClass : requireClass(cname);
      return MRef(cls, cf.utf8At(nt.a), cf.utf8At(nt.b));
    }) as MRef;
  }

  JClass? _staticHolder(JClass c, String name) {
    if (c.statics.containsKey(name)) return c;
    for (final i in c.interfaces) {
      final r = _staticHolder(i, name);
      if (r != null) return r;
    }
    return null;
  }

  FRef _fieldRef(JClass owner, int idx) {
    return owner.rcache.putIfAbsent(idx, () {
      final cf = owner.file!;
      final e = cf.constantPool[idx]!;
      final nt = cf.constantPool[e.b]!;
      final name = cf.utf8At(nt.a);
      final desc = cf.utf8At(nt.b);
      final cls = requireClass(cf.classNameAt(e.a));
      JClass? holder;
      for (JClass? c = cls; c != null && holder == null; c = c.superClass) {
        holder = _staticHolder(c, name);
      }
      return FRef(name, holder, desc == 'J' || desc == 'D');
    }) as FRef;
  }

  JClass _classAt(JClass owner, int idx) {
    return owner.rcache.putIfAbsent(idx, () {
      return requireClass(owner.file!.classNameAt(idx));
    }) as JClass;
  }

  // ------------------------------------------------------------- tableaux

  JArray _arrayOfType(String type, int n) {
    switch (type) {
      case '[Z':
      case '[B':
        return JArray(type, Int8List(n));
      case '[C':
        return JArray(type, Uint16List(n));
      case '[S':
        return JArray(type, Int16List(n));
      case '[I':
        return JArray(type, Int32List(n));
      case '[J':
        return JArray(type, Int64List(n));
      case '[F':
        return JArray(type, Float32List(n));
      case '[D':
        return JArray(type, Float64List(n));
      default:
        return JArray(type, List<Object?>.filled(n, null));
    }
  }

  JArray _newPrimArray(int atype, int n) {
    const types = {
      4: '[Z', 5: '[C', 6: '[F', 7: '[D', 8: '[B', 9: '[S', 10: '[I', 11: '[J',
    };
    return _arrayOfType(types[atype]!, n);
  }

  JArray _multi(String type, List<int> dims, int i) {
    final n = dims[i];
    if (i == dims.length - 1) return _arrayOfType(type, n);
    final elem = type.substring(1);
    final arr = List<Object?>.filled(n, null);
    for (var k = 0; k < n; k++) {
      arr[k] = _multi(elem, dims, i + 1);
    }
    return JArray(type, arr);
  }

  Object? _ldc(JClass owner, int idx) {
    final cf = owner.file!;
    final e = cf.constantPool[idx]!;
    switch (e.tag) {
      case 3:
      case 4:
      case 5:
      case 6:
        return e.value;
      case 8:
        return intern(cf.utf8At(e.a));
      default:
        return null;
    }
  }

  // ------------------------------------------------------------ exceptions

  void _raise(JThread t, JObject ex) {
    final trace = <String>[];
    while (t.frames.isNotEmpty) {
      final f = t.frames.last;
      final cf = f.method.owner.file!;
      for (final h in f.method.info!.code!.exceptions) {
        if (f.opPc >= h.startPc &&
            f.opPc < h.endPc &&
            (h.catchType == 0 || ex.cls.isSubclassOf(cf.classNameAt(h.catchType)))) {
          f.sp = 0;
          f.stack[f.sp++] = ex;
          f.pc = h.handlerPc;
          return;
        }
      }
      trace.add('   à ${f.method.owner.name}.${f.method.name}');
      t.frames.removeLast();
    }
    t.done = true;
    log('Exception non rattrapée (${t.name}) : ${ex.cls.name} ${ex.fields['message'] ?? ''}');
    for (final l in trace.take(5)) {
      log(l);
    }
  }

  // ----------------------------------------------------------- interpréteur

  void run(JThread t, int budget) {
    outer:
    while (budget > 0 && !t.done && !t.yielding && t.frames.isNotEmpty) {
      final f = t.frames.last;
      final st = f.stack;
      final lv = f.locals;
      final code = f.code;
      var pc = f.pc;
      var sp = f.sp;
      var opPc = pc;

      try {
        while (budget > 0) {
          budget--;
          opPc = pc;
          final op = code[pc++];

          // iload_n, lload_n, fload_n, dload_n, aload_n
          if (op >= 0x1a && op <= 0x2d) {
            final k = op - 0x1a;
            st[sp++] = lv[k & 3];
            final type = k >> 2;
            if (type == 1 || type == 3) st[sp++] = null;
            continue;
          }
          // istore_n, lstore_n, fstore_n, dstore_n, astore_n
          if (op >= 0x3b && op <= 0x4e) {
            final k = op - 0x3b;
            final type = k >> 2;
            if (type == 1 || type == 3) {
              sp -= 2;
              lv[k & 3] = st[sp];
            } else {
              lv[k & 3] = st[--sp];
            }
            continue;
          }
          // xaload
          if (op >= 0x2e && op <= 0x35) {
            final idx = st[--sp] as int;
            final arr = st[--sp];
            if (arr == null) throw JavaThrow('java/lang/NullPointerException');
            final a = arr as JArray;
            if (idx < 0 || idx >= a.data.length) {
              throw JavaThrow('java/lang/ArrayIndexOutOfBoundsException', '$idx');
            }
            st[sp++] = a.data[idx];
            if (op == 0x2f || op == 0x31) st[sp++] = null;
            continue;
          }
          // xastore
          if (op >= 0x4f && op <= 0x56) {
            Object? v;
            if (op == 0x50 || op == 0x52) {
              sp -= 2;
              v = st[sp];
            } else {
              v = st[--sp];
            }
            final idx = st[--sp] as int;
            final arr = st[--sp];
            if (arr == null) throw JavaThrow('java/lang/NullPointerException');
            final a = arr as JArray;
            if (idx < 0 || idx >= a.data.length) {
              throw JavaThrow('java/lang/ArrayIndexOutOfBoundsException', '$idx');
            }
            a.data[idx] = v;
            continue;
          }
          // ifeq .. if_acmpne
          if (op >= 0x99 && op <= 0xa6) {
            bool c;
            if (op <= 0x9e) {
              final v = st[--sp] as int;
              c = switch (op) {
                0x99 => v == 0,
                0x9a => v != 0,
                0x9b => v < 0,
                0x9c => v >= 0,
                0x9d => v > 0,
                _ => v <= 0,
              };
            } else if (op <= 0xa4) {
              final b = st[--sp] as int;
              final a = st[--sp] as int;
              c = switch (op) {
                0x9f => a == b,
                0xa0 => a != b,
                0xa1 => a < b,
                0xa2 => a >= b,
                0xa3 => a > b,
                _ => a <= b,
              };
            } else {
              final b = st[--sp];
              final a = st[--sp];
              c = op == 0xa5 ? identical(a, b) : !identical(a, b);
            }
            if (c) {
              pc = opPc + ((code[pc] << 8) | code[pc + 1]).toSigned(16);
            } else {
              pc += 2;
            }
            continue;
          }
          // xreturn
          if (op >= 0xac && op <= 0xb1) {
            Object? rv;
            var wide = false;
            var hasValue = true;
            if (op == 0xb1) {
              hasValue = false;
            } else if (op == 0xad || op == 0xaf) {
              sp -= 2;
              rv = st[sp];
              wide = true;
            } else {
              rv = st[--sp];
            }
            t.frames.removeLast();
            if (t.frames.isEmpty) {
              t.done = true;
              return;
            }
            if (hasValue) {
              final caller = t.frames.last;
              caller.stack[caller.sp++] = rv;
              if (wide) caller.stack[caller.sp++] = null;
            }
            continue outer;
          }

          switch (op) {
            case 0x00:
              break;
            case 0x01:
              st[sp++] = null;
              break;
            case 0x02:
            case 0x03:
            case 0x04:
            case 0x05:
            case 0x06:
            case 0x07:
            case 0x08:
              st[sp++] = op - 3;
              break;
            case 0x09:
            case 0x0a:
              st[sp++] = op - 0x09;
              st[sp++] = null;
              break;
            case 0x0b:
            case 0x0c:
            case 0x0d:
              st[sp++] = (op - 0x0b).toDouble();
              break;
            case 0x0e:
            case 0x0f:
              st[sp++] = (op - 0x0e).toDouble();
              st[sp++] = null;
              break;
            case 0x10:
              st[sp++] = code[pc++].toSigned(8);
              break;
            case 0x11:
              st[sp++] = ((code[pc] << 8) | code[pc + 1]).toSigned(16);
              pc += 2;
              break;
            case 0x12:
              st[sp++] = _ldc(f.method.owner, code[pc++]);
              break;
            case 0x13:
              st[sp++] = _ldc(f.method.owner, (code[pc] << 8) | code[pc + 1]);
              pc += 2;
              break;
            case 0x14:
              st[sp++] = _ldc(f.method.owner, (code[pc] << 8) | code[pc + 1]);
              st[sp++] = null;
              pc += 2;
              break;

            // loads avec index
            case 0x15:
            case 0x17:
            case 0x19:
              st[sp++] = lv[code[pc++]];
              break;
            case 0x16:
            case 0x18:
              st[sp++] = lv[code[pc++]];
              st[sp++] = null;
              break;
            // stores avec index
            case 0x36:
            case 0x38:
            case 0x3a:
              lv[code[pc++]] = st[--sp];
              break;
            case 0x37:
            case 0x39:
              sp -= 2;
              lv[code[pc++]] = st[sp];
              break;

            // pile
            case 0x57:
              sp--;
              break;
            case 0x58:
              sp -= 2;
              break;
            case 0x59:
              st[sp] = st[sp - 1];
              sp++;
              break;
            case 0x5a:
              {
                final v1 = st[sp - 1];
                final v2 = st[sp - 2];
                st[sp - 2] = v1;
                st[sp - 1] = v2;
                st[sp++] = v1;
                break;
              }
            case 0x5b:
              {
                final v1 = st[sp - 1];
                final v2 = st[sp - 2];
                final v3 = st[sp - 3];
                st[sp - 3] = v1;
                st[sp - 2] = v3;
                st[sp - 1] = v2;
                st[sp++] = v1;
                break;
              }
            case 0x5c:
              st[sp] = st[sp - 2];
              st[sp + 1] = st[sp - 1];
              sp += 2;
              break;
            case 0x5d:
              {
                final v1 = st[sp - 1];
                final v2 = st[sp - 2];
                final v3 = st[sp - 3];
                st[sp - 3] = v2;
                st[sp - 2] = v1;
                st[sp - 1] = v3;
                st[sp] = v2;
                st[sp + 1] = v1;
                sp += 2;
                break;
              }
            case 0x5e:
              {
                final v1 = st[sp - 1];
                final v2 = st[sp - 2];
                final v3 = st[sp - 3];
                final v4 = st[sp - 4];
                st[sp - 4] = v2;
                st[sp - 3] = v1;
                st[sp - 2] = v4;
                st[sp - 1] = v3;
                st[sp] = v2;
                st[sp + 1] = v1;
                sp += 2;
                break;
              }
            case 0x5f:
              {
                final v1 = st[sp - 1];
                st[sp - 1] = st[sp - 2];
                st[sp - 2] = v1;
                break;
              }

            // addition
            case 0x60:
              sp--;
              st[sp - 1] = ((st[sp - 1] as int) + (st[sp] as int)).toSigned(32);
              break;
            case 0x61:
              sp -= 4;
              st[sp] = (st[sp] as int) + (st[sp + 2] as int);
              sp += 2;
              break;
            case 0x62:
              sp--;
              st[sp - 1] = f32((st[sp - 1] as double) + (st[sp] as double));
              break;
            case 0x63:
              sp -= 4;
              st[sp] = (st[sp] as double) + (st[sp + 2] as double);
              sp += 2;
              break;
            // soustraction
            case 0x64:
              sp--;
              st[sp - 1] = ((st[sp - 1] as int) - (st[sp] as int)).toSigned(32);
              break;
            case 0x65:
              sp -= 4;
              st[sp] = (st[sp] as int) - (st[sp + 2] as int);
              sp += 2;
              break;
            case 0x66:
              sp--;
              st[sp - 1] = f32((st[sp - 1] as double) - (st[sp] as double));
              break;
            case 0x67:
              sp -= 4;
              st[sp] = (st[sp] as double) - (st[sp + 2] as double);
              sp += 2;
              break;
            // multiplication
            case 0x68:
              sp--;
              st[sp - 1] = ((st[sp - 1] as int) * (st[sp] as int)).toSigned(32);
              break;
            case 0x69:
              sp -= 4;
              st[sp] = (st[sp] as int) * (st[sp + 2] as int);
              sp += 2;
              break;
            case 0x6a:
              sp--;
              st[sp - 1] = f32((st[sp - 1] as double) * (st[sp] as double));
              break;
            case 0x6b:
              sp -= 4;
              st[sp] = (st[sp] as double) * (st[sp + 2] as double);
              sp += 2;
              break;
            // division
            case 0x6c:
              {
                sp--;
                final b = st[sp] as int;
                if (b == 0) throw JavaThrow('java/lang/ArithmeticException', '/ by zero');
                st[sp - 1] = ((st[sp - 1] as int) ~/ b).toSigned(32);
                break;
              }
            case 0x6d:
              {
                sp -= 4;
                final b = st[sp + 2] as int;
                if (b == 0) throw JavaThrow('java/lang/ArithmeticException', '/ by zero');
                st[sp] = (st[sp] as int) ~/ b;
                sp += 2;
                break;
              }
            case 0x6e:
              sp--;
              st[sp - 1] = f32((st[sp - 1] as double) / (st[sp] as double));
              break;
            case 0x6f:
              sp -= 4;
              st[sp] = (st[sp] as double) / (st[sp + 2] as double);
              sp += 2;
              break;
            // reste
            case 0x70:
              {
                sp--;
                final b = st[sp] as int;
                if (b == 0) throw JavaThrow('java/lang/ArithmeticException', '/ by zero');
                st[sp - 1] = (st[sp - 1] as int).remainder(b);
                break;
              }
            case 0x71:
              {
                sp -= 4;
                final b = st[sp + 2] as int;
                if (b == 0) throw JavaThrow('java/lang/ArithmeticException', '/ by zero');
                st[sp] = (st[sp] as int).remainder(b);
                sp += 2;
                break;
              }
            case 0x72:
              sp--;
              st[sp - 1] = f32((st[sp - 1] as double).remainder(st[sp] as double));
              break;
            case 0x73:
              sp -= 4;
              st[sp] = (st[sp] as double).remainder(st[sp + 2] as double);
              sp += 2;
              break;
            // négation
            case 0x74:
              st[sp - 1] = (-(st[sp - 1] as int)).toSigned(32);
              break;
            case 0x75:
              st[sp - 2] = -(st[sp - 2] as int);
              break;
            case 0x76:
              st[sp - 1] = -(st[sp - 1] as double);
              break;
            case 0x77:
              st[sp - 2] = -(st[sp - 2] as double);
              break;
            // décalages
            case 0x78:
              sp--;
              st[sp - 1] = ((st[sp - 1] as int) << ((st[sp] as int) & 31)).toSigned(32);
              break;
            case 0x79:
              sp--;
              st[sp - 2] = (st[sp - 2] as int) << ((st[sp] as int) & 63);
              break;
            case 0x7a:
              sp--;
              st[sp - 1] = (st[sp - 1] as int) >> ((st[sp] as int) & 31);
              break;
            case 0x7b:
              sp--;
              st[sp - 2] = (st[sp - 2] as int) >> ((st[sp] as int) & 63);
              break;
            case 0x7c:
              sp--;
              st[sp - 1] =
                  (((st[sp - 1] as int) & 0xFFFFFFFF) >> ((st[sp] as int) & 31)).toSigned(32);
              break;
            case 0x7d:
              sp--;
              st[sp - 2] = (st[sp - 2] as int) >>> ((st[sp] as int) & 63);
              break;
            // logique
            case 0x7e:
              sp--;
              st[sp - 1] = (st[sp - 1] as int) & (st[sp] as int);
              break;
            case 0x7f:
              sp -= 4;
              st[sp] = (st[sp] as int) & (st[sp + 2] as int);
              sp += 2;
              break;
            case 0x80:
              sp--;
              st[sp - 1] = (st[sp - 1] as int) | (st[sp] as int);
              break;
            case 0x81:
              sp -= 4;
              st[sp] = (st[sp] as int) | (st[sp + 2] as int);
              sp += 2;
              break;
            case 0x82:
              sp--;
              st[sp - 1] = (st[sp - 1] as int) ^ (st[sp] as int);
              break;
            case 0x83:
              sp -= 4;
              st[sp] = (st[sp] as int) ^ (st[sp + 2] as int);
              sp += 2;
              break;
            case 0x84:
              {
                final i = code[pc++];
                final c = code[pc++].toSigned(8);
                lv[i] = ((lv[i] as int) + c).toSigned(32);
                break;
              }

            // conversions
            case 0x85:
              st[sp++] = null;
              break;
            case 0x86:
              st[sp - 1] = f32((st[sp - 1] as int).toDouble());
              break;
            case 0x87:
              st[sp - 1] = (st[sp - 1] as int).toDouble();
              st[sp++] = null;
              break;
            case 0x88:
              sp -= 2;
              st[sp] = (st[sp] as int).toSigned(32);
              sp++;
              break;
            case 0x89:
              sp--;
              st[sp - 1] = f32((st[sp - 1] as int).toDouble());
              break;
            case 0x8a:
              st[sp - 2] = (st[sp - 2] as int).toDouble();
              break;
            case 0x8b:
              st[sp - 1] = d2i(st[sp - 1] as double);
              break;
            case 0x8c:
              st[sp - 1] = d2l(st[sp - 1] as double);
              st[sp++] = null;
              break;
            case 0x8d:
              st[sp++] = null;
              break;
            case 0x8e:
              sp--;
              st[sp - 1] = d2i(st[sp - 1] as double);
              break;
            case 0x8f:
              st[sp - 2] = d2l(st[sp - 2] as double);
              break;
            case 0x90:
              sp--;
              st[sp - 1] = f32(st[sp - 1] as double);
              break;
            case 0x91:
              st[sp - 1] = (st[sp - 1] as int).toSigned(8);
              break;
            case 0x92:
              st[sp - 1] = (st[sp - 1] as int) & 0xFFFF;
              break;
            case 0x93:
              st[sp - 1] = (st[sp - 1] as int).toSigned(16);
              break;

            // comparaisons
            case 0x94:
              {
                sp -= 4;
                final a = st[sp] as int;
                final b = st[sp + 2] as int;
                st[sp++] = a < b ? -1 : (a > b ? 1 : 0);
                break;
              }
            case 0x95:
            case 0x96:
              {
                sp--;
                final b = st[sp] as double;
                final a = st[sp - 1] as double;
                st[sp - 1] = (a.isNaN || b.isNaN)
                    ? (op == 0x95 ? -1 : 1)
                    : (a < b ? -1 : (a > b ? 1 : 0));
                break;
              }
            case 0x97:
            case 0x98:
              {
                sp -= 4;
                final a = st[sp] as double;
                final b = st[sp + 2] as double;
                st[sp++] = (a.isNaN || b.isNaN)
                    ? (op == 0x97 ? -1 : 1)
                    : (a < b ? -1 : (a > b ? 1 : 0));
                break;
              }

            // sauts
            case 0xa7:
              pc = opPc + ((code[pc] << 8) | code[pc + 1]).toSigned(16);
              break;
            case 0xc8:
              pc = opPc + _i32(code, pc);
              break;
            case 0xc6:
            case 0xc7:
              {
                final v = st[--sp];
                if ((v == null) == (op == 0xc6)) {
                  pc = opPc + ((code[pc] << 8) | code[pc + 1]).toSigned(16);
                } else {
                  pc += 2;
                }
                break;
              }
            case 0xaa:
              {
                final p = (opPc + 4) & ~3;
                final def = _i32(code, p);
                final low = _i32(code, p + 4);
                final high = _i32(code, p + 8);
                final key = st[--sp] as int;
                if (key < low || key > high) {
                  pc = opPc + def;
                } else {
                  pc = opPc + _i32(code, p + 12 + (key - low) * 4);
                }
                break;
              }
            case 0xab:
              {
                final p = (opPc + 4) & ~3;
                final def = _i32(code, p);
                final n = _i32(code, p + 4);
                final key = st[--sp] as int;
                var target = def;
                for (var i = 0; i < n; i++) {
                  if (_i32(code, p + 8 + i * 8) == key) {
                    target = _i32(code, p + 12 + i * 8);
                    break;
                  }
                }
                pc = opPc + target;
                break;
              }

            // champs
            case 0xb2:
              {
                final fr = _fieldRef(f.method.owner, (code[pc] << 8) | code[pc + 1]);
                pc += 2;
                final h = fr.holder;
                if (h == null) {
                  throw JavaThrow('java/lang/NoSuchFieldError', fr.name);
                }
                if (ensureInit(t, h)) {
                  f.pc = opPc;
                  f.sp = sp;
                  f.opPc = opPc;
                  continue outer;
                }
                st[sp++] = h.statics[fr.name];
                if (fr.wide) st[sp++] = null;
                break;
              }
            case 0xb3:
              {
                final fr = _fieldRef(f.method.owner, (code[pc] << 8) | code[pc + 1]);
                pc += 2;
                final h = fr.holder;
                if (h == null) {
                  throw JavaThrow('java/lang/NoSuchFieldError', fr.name);
                }
                if (ensureInit(t, h)) {
                  f.pc = opPc;
                  f.sp = sp;
                  f.opPc = opPc;
                  continue outer;
                }
                if (fr.wide) sp--;
                h.statics[fr.name] = st[--sp];
                break;
              }
            case 0xb4:
              {
                final fr = _fieldRef(f.method.owner, (code[pc] << 8) | code[pc + 1]);
                pc += 2;
                final o = st[--sp];
                if (o == null) throw JavaThrow('java/lang/NullPointerException');
                st[sp++] = (o as JObject).fields[fr.name];
                if (fr.wide) st[sp++] = null;
                break;
              }
            case 0xb5:
              {
                final fr = _fieldRef(f.method.owner, (code[pc] << 8) | code[pc + 1]);
                pc += 2;
                if (fr.wide) sp--;
                final v = st[--sp];
                final o = st[--sp];
                if (o == null) throw JavaThrow('java/lang/NullPointerException');
                (o as JObject).fields[fr.name] = v;
                break;
              }

            // appels
            case 0xb6:
            case 0xb7:
            case 0xb8:
            case 0xb9:
              {
                final idx = (code[pc] << 8) | code[pc + 1];
                pc += op == 0xb9 ? 4 : 2;
                final mr = _methodRef(f.method.owner, idx);
                if (op == 0xb8 && ensureInit(t, mr.cls)) {
                  f.pc = opPc;
                  f.sp = sp;
                  f.opPc = opPc;
                  continue outer;
                }
                final hasRecv = op != 0xb8;
                final na = mr.sig.args.length;
                final args = List<Object?>.filled(na + (hasRecv ? 1 : 0), null);
                var ai = args.length - 1;
                for (var i = na - 1; i >= 0; i--) {
                  final k = mr.sig.args[i];
                  sp -= (k == 'J' || k == 'D') ? 2 : 1;
                  args[ai--] = st[sp];
                }
                if (hasRecv) args[0] = st[--sp];

                JMethod? m;
                if (op == 0xb8 || op == 0xb7) {
                  if (hasRecv && args[0] == null) {
                    throw JavaThrow('java/lang/NullPointerException');
                  }
                  m = mr.direct ??= findMethod(mr.cls, mr.name, mr.desc);
                } else {
                  final recv = args[0];
                  if (recv == null) throw JavaThrow('java/lang/NullPointerException');
                  if (recv is JArray && mr.name == 'clone') {
                    st[sp++] = recv.copy();
                    break;
                  }
                  m = findMethod(classOf(recv), mr.name, mr.desc);
                }
                if (m == null) {
                  log('Méthode non implémentée : ${mr.cls.name}.${mr.name}${mr.desc}');
                  throw JavaThrow(
                    'java/lang/NoSuchMethodError',
                    '${mr.cls.name}.${mr.name}${mr.desc}',
                  );
                }

                final nf = m.native;
                if (nf != null) {
                  f.pc = pc;
                  f.sp = sp;
                  f.opPc = opPc;
                  final r = nf(this, t, args);
                  if (!identical(t.frames.last, f)) continue outer;
                  if (mr.name == '<init>' && identical(mr.cls, stringClass) && r != null) {
                    // new String(...) : l'objet provisoire est remplacé partout
                    // par la vraie chaîne.
                    final ph = args[0];
                    for (var i = 0; i < sp; i++) {
                      if (identical(st[i], ph)) st[i] = r;
                    }
                    for (var i = 0; i < lv.length; i++) {
                      if (identical(lv[i], ph)) lv[i] = r;
                    }
                    break;
                  }
                  if (mr.sig.ret != 'V') {
                    st[sp++] = r;
                    if (mr.sig.ret == 'J' || mr.sig.ret == 'D') st[sp++] = null;
                  }
                  if (t.yielding) {
                    f.pc = pc;
                    f.sp = sp;
                    continue outer;
                  }
                  break;
                }

                if (m.info?.code == null) {
                  log('Méthode native manquante : ${m.owner.name}.${m.name}${m.desc}');
                  throw JavaThrow(
                    'java/lang/UnsatisfiedLinkError',
                    '${m.owner.name}.${m.name}${m.desc}',
                  );
                }
                if (t.frames.length > 1500) {
                  throw JavaThrow('java/lang/StackOverflowError');
                }
                f.pc = pc;
                f.sp = sp;
                f.opPc = opPc;
                t.frames.add(newFrame(m, args));
                continue outer;
              }

            // objets et tableaux
            case 0xbb:
              {
                final cls = _classAt(f.method.owner, (code[pc] << 8) | code[pc + 1]);
                pc += 2;
                if (ensureInit(t, cls)) {
                  f.pc = opPc;
                  f.sp = sp;
                  f.opPc = opPc;
                  continue outer;
                }
                st[sp++] = JObject.withDefaults(cls);
                break;
              }
            case 0xbc:
              {
                final n = st[sp - 1] as int;
                if (n < 0) throw JavaThrow('java/lang/NegativeArraySizeException', '$n');
                st[sp - 1] = _newPrimArray(code[pc++], n);
                break;
              }
            case 0xbd:
              {
                final cname = f.method.owner.file!
                    .classNameAt((code[pc] << 8) | code[pc + 1]);
                pc += 2;
                final n = st[sp - 1] as int;
                if (n < 0) throw JavaThrow('java/lang/NegativeArraySizeException', '$n');
                final type = cname.startsWith('[') ? '[$cname' : '[L$cname;';
                st[sp - 1] = JArray(type, List<Object?>.filled(n, null));
                break;
              }
            case 0xbe:
              {
                final a = st[sp - 1];
                if (a == null) throw JavaThrow('java/lang/NullPointerException');
                st[sp - 1] = (a as JArray).data.length;
                break;
              }
            case 0xbf:
              {
                final ex = st[--sp];
                if (ex == null) throw JavaThrow('java/lang/NullPointerException');
                f.pc = pc;
                f.sp = sp;
                f.opPc = opPc;
                _raise(t, ex as JObject);
                continue outer;
              }
            case 0xc0:
              {
                final cname = f.method.owner.file!
                    .classNameAt((code[pc] << 8) | code[pc + 1]);
                pc += 2;
                final o = st[sp - 1];
                if (o != null && !isInstance(o, cname)) {
                  throw JavaThrow('java/lang/ClassCastException', cname);
                }
                break;
              }
            case 0xc1:
              {
                final cname = f.method.owner.file!
                    .classNameAt((code[pc] << 8) | code[pc + 1]);
                pc += 2;
                st[sp - 1] = isInstance(st[sp - 1], cname) ? 1 : 0;
                break;
              }
            case 0xc2:
            case 0xc3:
              sp--;
              break;
            case 0xc4:
              {
                final wop = code[pc++];
                final idx = (code[pc] << 8) | code[pc + 1];
                pc += 2;
                switch (wop) {
                  case 0x15:
                  case 0x17:
                  case 0x19:
                    st[sp++] = lv[idx];
                    break;
                  case 0x16:
                  case 0x18:
                    st[sp++] = lv[idx];
                    st[sp++] = null;
                    break;
                  case 0x36:
                  case 0x38:
                  case 0x3a:
                    lv[idx] = st[--sp];
                    break;
                  case 0x37:
                  case 0x39:
                    sp -= 2;
                    lv[idx] = st[sp];
                    break;
                  case 0x84:
                    {
                      final c = ((code[pc] << 8) | code[pc + 1]).toSigned(16);
                      pc += 2;
                      lv[idx] = ((lv[idx] as int) + c).toSigned(32);
                      break;
                    }
                  default:
                    throw JavaThrow('java/lang/Error', 'wide 0x${wop.toRadixString(16)}');
                }
                break;
              }
            case 0xc5:
              {
                final cname = f.method.owner.file!
                    .classNameAt((code[pc] << 8) | code[pc + 1]);
                final nd = code[pc + 2];
                pc += 3;
                final dims = List<int>.filled(nd, 0);
                for (var i = nd - 1; i >= 0; i--) {
                  dims[i] = st[--sp] as int;
                  if (dims[i] < 0) {
                    throw JavaThrow('java/lang/NegativeArraySizeException', '${dims[i]}');
                  }
                }
                st[sp++] = _multi(cname, dims, 0);
                break;
              }

            default:
              throw JavaThrow(
                'java/lang/Error',
                'opcode non géré 0x${op.toRadixString(16)}',
              );
          }
        }
        // Budget épuisé : on sauvegarde l'état.
        f.pc = pc;
        f.sp = sp;
        f.opPc = opPc;
      } on JavaThrow catch (e) {
        f.pc = pc;
        f.sp = sp;
        f.opPc = opPc;
        _raise(t, makeThrowable(e.cls, e.msg));
      } catch (e, s) {
        f.pc = pc;
        f.sp = sp;
        f.opPc = opPc;
        log('Erreur interne dans ${f.method.owner.name}.${f.method.name} (pc=$opPc) : $e');
        log(s.toString().split('\n').take(3).join('\n'));
        t.done = true;
      }
    }
  }
}
