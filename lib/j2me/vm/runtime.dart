import 'dart:typed_data';

import '../class_parser.dart';
import 'vm.dart';

/// Fonction native : reçoit la VM, le thread courant et les arguments logiques
/// (récepteur en premier pour les méthodes d'instance ; un long ou un double
/// compte pour UN seul argument ici).
typedef NativeFn = Object? Function(Vm vm, JThread t, List<Object?> args);

/// Exception Java levée depuis du code Dart (VM ou natives).
class JavaThrow implements Exception {
  JavaThrow(this.cls, [this.msg]);

  final String cls;
  final String? msg;
}

/// Descripteur de méthode décomposé.
/// Types : I (int, short, byte, char, boolean), J, F, D, L (références), V.
class Sig {
  const Sig(this.args, this.ret);

  final List<String> args;
  final String ret;

  static final Map<String, Sig> _cache = {};

  static Sig of(String d) => _cache.putIfAbsent(d, () => _parse(d));

  static String _kind(String c) {
    switch (c) {
      case 'J':
      case 'F':
      case 'D':
      case 'V':
        return c;
      case 'L':
      case '[':
        return 'L';
      default:
        return 'I';
    }
  }

  static Sig _parse(String d) {
    final args = <String>[];
    var i = 1;
    while (d[i] != ')') {
      final c = d[i];
      if (c == 'L') {
        i = d.indexOf(';', i) + 1;
        args.add('L');
      } else if (c == '[') {
        while (d[i] == '[') {
          i++;
        }
        if (d[i] == 'L') {
          i = d.indexOf(';', i) + 1;
        } else {
          i++;
        }
        args.add('L');
      } else {
        args.add(_kind(c));
        i++;
      }
    }
    return Sig(args, _kind(d[i + 1]));
  }
}

class JMethod {
  JMethod(this.owner, this.name, this.desc, this.info, this.native)
      : sig = Sig.of(desc);

  final JClass owner;
  final String name;
  final String desc;
  final MemberInfo? info;
  final NativeFn? native;
  final Sig sig;

  bool get isStatic => info?.isStatic ?? false;
}

class JClass {
  JClass(
    this.name,
    this.file,
    this.superClass,
    this.interfaces, {
    this.builtinInterface = false,
  });

  final String name;
  final ClassFile? file;
  final JClass? superClass;
  final List<JClass> interfaces;
  final bool builtinInterface;

  final Map<String, Object?> statics = {};
  final Map<String, JMethod?> methodCache = {};

  /// Caches de résolution (index du constant pool -> référence résolue).
  final Map<int, Object> rcache = {};

  bool initialized = false;
  Map<String, Object?>? _defaults;

  bool get isInterface =>
      builtinInterface || (file != null && (file!.accessFlags & 0x0200) != 0);

  bool isSubclassOf(String n) {
    for (JClass? c = this; c != null; c = c.superClass) {
      if (c.name == n) return true;
      for (final i in c.interfaces) {
        if (i.isSubclassOf(n)) return true;
      }
    }
    return false;
  }

  /// Valeurs par défaut des champs d'instance (classe + parents).
  Map<String, Object?> fieldDefaults() {
    final cached = _defaults;
    if (cached != null) return cached;
    final m = <String, Object?>{};
    if (superClass != null) m.addAll(superClass!.fieldDefaults());
    final f = file;
    if (f != null) {
      for (final fld in f.fields) {
        if (!fld.isStatic) m[fld.name] = defaultFor(fld.descriptor);
      }
    }
    return _defaults = m;
  }

  static Object? defaultFor(String desc) {
    switch (desc[0]) {
      case 'J':
      case 'B':
      case 'C':
      case 'S':
      case 'I':
      case 'Z':
        return 0;
      case 'F':
      case 'D':
        return 0.0;
      default:
        return null;
    }
  }
}

class JObject {
  JObject(this.cls);

  JObject.withDefaults(this.cls) {
    fields.addAll(cls.fieldDefaults());
  }

  final JClass cls;
  final Map<String, Object?> fields = {};

  /// État interne pour les classes natives (StringBuffer, Vector, Random...).
  Object? native;
}

class JArray {
  JArray(this.type, this.data);

  /// Descripteur du tableau, par exemple "[I" ou "[Ljava/lang/String;".
  final String type;
  final List<dynamic> data;

  int get length => data.length;

  JArray copy() {
    final d = data;
    final List<dynamic> c;
    if (d is Int8List) {
      c = Int8List.fromList(d);
    } else if (d is Int16List) {
      c = Int16List.fromList(d);
    } else if (d is Uint16List) {
      c = Uint16List.fromList(d);
    } else if (d is Int32List) {
      c = Int32List.fromList(d);
    } else if (d is Int64List) {
      c = Int64List.fromList(d);
    } else if (d is Float32List) {
      c = Float32List.fromList(d);
    } else if (d is Float64List) {
      c = Float64List.fromList(d);
    } else {
      c = List<Object?>.from(d);
    }
    return JArray(type, c);
  }
}

class Frame {
  Frame(this.method, this.locals, this.stack)
      : code = method.info!.code!.code;

  final JMethod method;
  final List<Object?> locals;
  final List<Object?> stack;
  final Uint8List code;

  int pc = 0;
  int sp = 0;

  /// Adresse de l'instruction en cours (sert à trouver le bon handler).
  int opPc = 0;
}

class JThread {
  JThread(this.name);

  final String name;
  final List<Frame> frames = [];
  int wakeAt = 0;
  bool yielding = false;
  bool done = false;

  /// Objet java.lang.Thread associé (créé à la demande).
  JObject? threadObject;
}
