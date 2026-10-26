import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'vm.dart';

/// Enregistre les classes natives et leurs méthodes.
/// Les natives MIDP (Canvas, Graphics...) viendront dans un autre fichier.
void registerNatives(Vm vm) {
  _defineClasses(vm);
  _object(vm);
  _string(vm);
  _stringBuffer(vm);
  _boxes(vm);
  _math(vm);
  _system(vm);
  _throwable(vm);
  _thread(vm);
  _random(vm);
  _vector(vm);
  _midlet(vm);
}

void _defineClasses(Vm vm) {
  vm.defineClass('java/lang/Object', null);
  for (final n in const [
    'java/lang/String',
    'java/lang/StringBuffer',
    'java/lang/Integer',
    'java/lang/Character',
    'java/lang/Math',
    'java/lang/System',
    'java/io/PrintStream',
    'java/util/Random',
    'java/util/Vector',
    'javax/microedition/midlet/MIDlet',
  ]) {
    vm.defineClass(n, 'java/lang/Object');
  }
  vm.defineClass('java/lang/Runnable', 'java/lang/Object', iface: true);
  vm.defineClass('java/lang/Thread', 'java/lang/Object', interfaces: ['java/lang/Runnable']);

  const hierarchy = <(String, String)>[
    ('java/lang/Throwable', 'java/lang/Object'),
    ('java/lang/Exception', 'java/lang/Throwable'),
    ('java/lang/Error', 'java/lang/Throwable'),
    ('java/lang/RuntimeException', 'java/lang/Exception'),
    ('java/lang/NullPointerException', 'java/lang/RuntimeException'),
    ('java/lang/ArithmeticException', 'java/lang/RuntimeException'),
    ('java/lang/ClassCastException', 'java/lang/RuntimeException'),
    ('java/lang/IllegalArgumentException', 'java/lang/RuntimeException'),
    ('java/lang/NumberFormatException', 'java/lang/IllegalArgumentException'),
    ('java/lang/IllegalStateException', 'java/lang/RuntimeException'),
    ('java/lang/IndexOutOfBoundsException', 'java/lang/RuntimeException'),
    ('java/lang/ArrayIndexOutOfBoundsException', 'java/lang/IndexOutOfBoundsException'),
    ('java/lang/StringIndexOutOfBoundsException', 'java/lang/IndexOutOfBoundsException'),
    ('java/lang/NegativeArraySizeException', 'java/lang/RuntimeException'),
    ('java/lang/ArrayStoreException', 'java/lang/RuntimeException'),
    ('java/lang/SecurityException', 'java/lang/RuntimeException'),
    ('java/util/NoSuchElementException', 'java/lang/RuntimeException'),
    ('java/util/EmptyStackException', 'java/lang/RuntimeException'),
    ('java/lang/InterruptedException', 'java/lang/Exception'),
    ('java/io/IOException', 'java/lang/Exception'),
    ('javax/microedition/midlet/MIDletStateChangeException', 'java/lang/Exception'),
    ('java/lang/VirtualMachineError', 'java/lang/Error'),
    ('java/lang/OutOfMemoryError', 'java/lang/VirtualMachineError'),
    ('java/lang/StackOverflowError', 'java/lang/VirtualMachineError'),
    ('java/lang/LinkageError', 'java/lang/Error'),
    ('java/lang/NoClassDefFoundError', 'java/lang/LinkageError'),
    ('java/lang/UnsatisfiedLinkError', 'java/lang/LinkageError'),
    ('java/lang/IncompatibleClassChangeError', 'java/lang/LinkageError'),
    ('java/lang/AbstractMethodError', 'java/lang/IncompatibleClassChangeError'),
    ('java/lang/NoSuchMethodError', 'java/lang/IncompatibleClassChangeError'),
    ('java/lang/NoSuchFieldError', 'java/lang/IncompatibleClassChangeError'),
  ];
  for (final (name, sup) in hierarchy) {
    vm.defineClass(name, sup);
  }
}

// ------------------------------------------------------------------ formats

String fmtDouble(double d) {
  if (d.isNaN) return 'NaN';
  if (d.isInfinite) return d < 0 ? '-Infinity' : 'Infinity';
  if (d == d.truncateToDouble() && d.abs() < 1e7) return '${d.toInt()}.0';
  return d.toString();
}

/// Convertit un argument selon la lettre de type du descripteur.
String _conv(Vm vm, String kind, Object? v) {
  switch (kind) {
    case 'C':
      return String.fromCharCode(v as int);
    case 'Z':
      return (v as int) != 0 ? 'true' : 'false';
    case 'I':
    case 'J':
      return '$v';
    case 'F':
    case 'D':
      return fmtDouble(v as double);
    case '[C':
      return String.fromCharCodes((v as JArray).data.cast<int>());
    default:
      return vm.str(v);
  }
}

/// Surcharges communes de print/println/append : descripteur -> lettre de type.
const Map<String, String> _printTypes = {
  'Ljava/lang/String;': 'L',
  'Ljava/lang/Object;': 'L',
  'I': 'I',
  'C': 'C',
  'Z': 'Z',
  'J': 'J',
  'F': 'F',
  'D': 'D',
  '[C': '[C',
};

// ------------------------------------------------------------------- Object

void _object(Vm vm) {
  final n = vm.natives;
  n['java/lang/Object.<init>()V'] = (vm, t, a) => null;
  n['java/lang/Object.hashCode()I'] = (vm, t, a) => identityHashCode(a[0]) & 0x7FFFFFFF;
  n['java/lang/Object.equals(Ljava/lang/Object;)Z'] =
      (vm, t, a) => vm.javaEquals(a[0], a[1]) ? 1 : 0;
  n['java/lang/Object.toString()Ljava/lang/String;'] = (vm, t, a) => vm.str(a[0]);
  n['java/lang/Object.notify()V'] = (vm, t, a) => null;
  n['java/lang/Object.notifyAll()V'] = (vm, t, a) => null;
  n['java/lang/Object.wait()V'] = (vm, t, a) {
    t.wakeAt = vm.nowMs + 5;
    t.yielding = true;
    return null;
  };
  n['java/lang/Object.wait(J)V'] = (vm, t, a) {
    final ms = (a[1] as int).clamp(1, 50);
    t.wakeAt = vm.nowMs + ms;
    t.yielding = true;
    return null;
  };
}

// ------------------------------------------------------------------- String

int _cmp(String a, String b) {
  final n = math.min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    final d = a.codeUnitAt(i) - b.codeUnitAt(i);
    if (d != 0) return d;
  }
  return a.length - b.length;
}

String _bytesToString(Int8List b, int off, int len) =>
    utf8.decode(Uint8List.sublistView(b, off, off + len), allowMalformed: true);

void _string(Vm vm) {
  final n = vm.natives;
  const c = 'java/lang/String';
  String s(List<Object?> a) => a[0] as String;
  String arg(List<Object?> a, int i) {
    final v = a[i];
    if (v == null) throw JavaThrow('java/lang/NullPointerException');
    return v as String;
  }

  n['$c.length()I'] = (vm, t, a) => s(a).length;
  n['$c.charAt(I)C'] = (vm, t, a) {
    final i = a[1] as int;
    final str = s(a);
    if (i < 0 || i >= str.length) {
      throw JavaThrow('java/lang/StringIndexOutOfBoundsException', '$i');
    }
    return str.codeUnitAt(i);
  };
  n['$c.equals(Ljava/lang/Object;)Z'] = (vm, t, a) => (a[1] is String && a[1] == a[0]) ? 1 : 0;
  n['$c.equalsIgnoreCase(Ljava/lang/String;)Z'] =
      (vm, t, a) => (a[1] is String && (a[1] as String).toLowerCase() == s(a).toLowerCase()) ? 1 : 0;
  n['$c.hashCode()I'] = (vm, t, a) {
    var h = 0;
    for (final u in s(a).codeUnits) {
      h = (31 * h + u).toSigned(32);
    }
    return h;
  };
  n['$c.toString()Ljava/lang/String;'] = (vm, t, a) => a[0];
  n['$c.substring(I)Ljava/lang/String;'] = (vm, t, a) {
    final i = a[1] as int;
    final str = s(a);
    if (i < 0 || i > str.length) {
      throw JavaThrow('java/lang/StringIndexOutOfBoundsException', '$i');
    }
    return str.substring(i);
  };
  n['$c.substring(II)Ljava/lang/String;'] = (vm, t, a) {
    final i = a[1] as int;
    final j = a[2] as int;
    final str = s(a);
    if (i < 0 || j > str.length || i > j) {
      throw JavaThrow('java/lang/StringIndexOutOfBoundsException', '$i..$j');
    }
    return str.substring(i, j);
  };
  n['$c.indexOf(I)I'] = (vm, t, a) => s(a).indexOf(String.fromCharCode(a[1] as int));
  n['$c.indexOf(II)I'] =
      (vm, t, a) => s(a).indexOf(String.fromCharCode(a[1] as int), math.max(0, a[2] as int));
  n['$c.indexOf(Ljava/lang/String;)I'] = (vm, t, a) => s(a).indexOf(arg(a, 1));
  n['$c.indexOf(Ljava/lang/String;I)I'] =
      (vm, t, a) => s(a).indexOf(arg(a, 1), math.max(0, a[2] as int));
  n['$c.lastIndexOf(I)I'] = (vm, t, a) => s(a).lastIndexOf(String.fromCharCode(a[1] as int));
  n['$c.startsWith(Ljava/lang/String;)Z'] = (vm, t, a) => s(a).startsWith(arg(a, 1)) ? 1 : 0;
  n['$c.endsWith(Ljava/lang/String;)Z'] = (vm, t, a) => s(a).endsWith(arg(a, 1)) ? 1 : 0;
  n['$c.toLowerCase()Ljava/lang/String;'] = (vm, t, a) => s(a).toLowerCase();
  n['$c.toUpperCase()Ljava/lang/String;'] = (vm, t, a) => s(a).toUpperCase();
  n['$c.trim()Ljava/lang/String;'] = (vm, t, a) => s(a).trim();
  n['$c.concat(Ljava/lang/String;)Ljava/lang/String;'] = (vm, t, a) => s(a) + arg(a, 1);
  n['$c.compareTo(Ljava/lang/String;)I'] = (vm, t, a) => _cmp(s(a), arg(a, 1));
  n['$c.toCharArray()[C'] = (vm, t, a) => JArray('[C', Uint16List.fromList(s(a).codeUnits));
  n['$c.getBytes()[B'] = (vm, t, a) => JArray('[B', Int8List.fromList(utf8.encode(s(a))));

  // String.valueOf(...)
  n['$c.valueOf(I)Ljava/lang/String;'] = (vm, t, a) => '${a[0]}';
  n['$c.valueOf(J)Ljava/lang/String;'] = (vm, t, a) => '${a[0]}';
  n['$c.valueOf(C)Ljava/lang/String;'] = (vm, t, a) => String.fromCharCode(a[0] as int);
  n['$c.valueOf(Z)Ljava/lang/String;'] = (vm, t, a) => (a[0] as int) != 0 ? 'true' : 'false';
  n['$c.valueOf(F)Ljava/lang/String;'] = (vm, t, a) => fmtDouble(a[0] as double);
  n['$c.valueOf(D)Ljava/lang/String;'] = (vm, t, a) => fmtDouble(a[0] as double);
  n['$c.valueOf(Ljava/lang/Object;)Ljava/lang/String;'] = (vm, t, a) => vm.str(a[0]);
  n['$c.valueOf([C)Ljava/lang/String;'] = (vm, t, a) => _conv(vm, '[C', a[0]);

  // Constructeurs : renvoient la vraie chaîne, la VM remplace l'objet provisoire.
  n['$c.<init>()V'] = (vm, t, a) => '';
  n['$c.<init>(Ljava/lang/String;)V'] = (vm, t, a) => arg(a, 1);
  n['$c.<init>([C)V'] = (vm, t, a) => _conv(vm, '[C', a[1]);
  n['$c.<init>([CII)V'] = (vm, t, a) {
    final d = (a[1] as JArray).data.cast<int>();
    final o = a[2] as int;
    return String.fromCharCodes(d.sublist(o, o + (a[3] as int)));
  };
  n['$c.<init>([B)V'] = (vm, t, a) {
    final b = (a[1] as JArray).data as Int8List;
    return _bytesToString(b, 0, b.length);
  };
  n['$c.<init>([BII)V'] =
      (vm, t, a) => _bytesToString((a[1] as JArray).data as Int8List, a[2] as int, a[3] as int);
  n['$c.<init>([BLjava/lang/String;)V'] = (vm, t, a) {
    final b = (a[1] as JArray).data as Int8List;
    return _bytesToString(b, 0, b.length);
  };
}

// ------------------------------------------------------------- StringBuffer

void _stringBuffer(Vm vm) {
  final n = vm.natives;
  const c = 'java/lang/StringBuffer';
  StringBuffer sb(List<Object?> a) => (a[0] as JObject).native as StringBuffer;
  void setText(List<Object?> a, String text) {
    final b = sb(a);
    b.clear();
    b.write(text);
  }

  n['$c.<init>()V'] = (vm, t, a) {
    (a[0] as JObject).native = StringBuffer();
    return null;
  };
  n['$c.<init>(I)V'] = n['$c.<init>()V']!;
  n['$c.<init>(Ljava/lang/String;)V'] = (vm, t, a) {
    if (a[1] == null) throw JavaThrow('java/lang/NullPointerException');
    (a[0] as JObject).native = StringBuffer(a[1] as String);
    return null;
  };

  _printTypes.forEach((desc, kind) {
    n['$c.append($desc)Ljava/lang/StringBuffer;'] = (vm, t, a) {
      sb(a).write(_conv(vm, kind, a[1]));
      return a[0];
    };
  });

  n['$c.toString()Ljava/lang/String;'] = (vm, t, a) => sb(a).toString();
  n['$c.length()I'] = (vm, t, a) => sb(a).length;
  n['$c.charAt(I)C'] = (vm, t, a) {
    final str = sb(a).toString();
    final i = a[1] as int;
    if (i < 0 || i >= str.length) {
      throw JavaThrow('java/lang/StringIndexOutOfBoundsException', '$i');
    }
    return str.codeUnitAt(i);
  };
  n['$c.reverse()Ljava/lang/StringBuffer;'] = (vm, t, a) {
    setText(a, String.fromCharCodes(sb(a).toString().codeUnits.reversed));
    return a[0];
  };
  n['$c.setLength(I)V'] = (vm, t, a) {
    final str = sb(a).toString();
    final len = a[1] as int;
    setText(a, len <= str.length ? str.substring(0, len) : str.padRight(len, '\u0000'));
    return null;
  };
  n['$c.insert(ILjava/lang/String;)Ljava/lang/StringBuffer;'] = (vm, t, a) {
    final str = sb(a).toString();
    final i = a[1] as int;
    if (i < 0 || i > str.length) {
      throw JavaThrow('java/lang/StringIndexOutOfBoundsException', '$i');
    }
    setText(a, str.substring(0, i) + vm.str(a[2]) + str.substring(i));
    return a[0];
  };
}

// ----------------------------------------------------- Integer et Character

void _boxes(Vm vm) {
  final n = vm.natives;
  const c = 'java/lang/Integer';
  final intClass = vm.classes[c]!;
  intClass.statics['MAX_VALUE'] = 2147483647;
  intClass.statics['MIN_VALUE'] = -2147483648;

  int parse(Object? v, int radix) {
    if (v == null) throw JavaThrow('java/lang/NumberFormatException', 'null');
    final str = v as String;
    final r = int.tryParse(str.startsWith('+') ? str.substring(1) : str, radix: radix);
    if (r == null || r > 2147483647 || r < -2147483648) {
      throw JavaThrow('java/lang/NumberFormatException', str);
    }
    return r;
  }

  n['$c.<init>(I)V'] = (vm, t, a) {
    (a[0] as JObject).native = a[1];
    return null;
  };
  n['$c.valueOf(I)Ljava/lang/Integer;'] = (vm, t, a) => JObject(intClass)..native = a[0];
  n['$c.intValue()I'] = (vm, t, a) => (a[0] as JObject).native;
  n['$c.toString()Ljava/lang/String;'] = (vm, t, a) => '${(a[0] as JObject).native}';
  n['$c.toString(I)Ljava/lang/String;'] = (vm, t, a) => '${a[0]}';
  n['$c.hashCode()I'] = (vm, t, a) => (a[0] as JObject).native;
  n['$c.equals(Ljava/lang/Object;)Z'] = (vm, t, a) => vm.javaEquals(a[0], a[1]) ? 1 : 0;
  n['$c.parseInt(Ljava/lang/String;)I'] = (vm, t, a) => parse(a[0], 10);
  n['$c.parseInt(Ljava/lang/String;I)I'] = (vm, t, a) => parse(a[0], a[1] as int);
  n['$c.toHexString(I)Ljava/lang/String;'] =
      (vm, t, a) => ((a[0] as int) & 0xFFFFFFFF).toRadixString(16);

  const ch = 'java/lang/Character';
  bool isDigit(int u) => u >= 48 && u <= 57;
  bool isUpper(int u) => u >= 65 && u <= 90;
  bool isLower(int u) => u >= 97 && u <= 122;
  n['$ch.isDigit(C)Z'] = (vm, t, a) => isDigit(a[0] as int) ? 1 : 0;
  n['$ch.isUpperCase(C)Z'] = (vm, t, a) => isUpper(a[0] as int) ? 1 : 0;
  n['$ch.isLowerCase(C)Z'] = (vm, t, a) => isLower(a[0] as int) ? 1 : 0;
  n['$ch.isLetter(C)Z'] =
      (vm, t, a) => (isUpper(a[0] as int) || isLower(a[0] as int)) ? 1 : 0;
  n['$ch.toUpperCase(C)C'] = (vm, t, a) =>
      String.fromCharCode(a[0] as int).toUpperCase().codeUnitAt(0);
  n['$ch.toLowerCase(C)C'] = (vm, t, a) =>
      String.fromCharCode(a[0] as int).toLowerCase().codeUnitAt(0);
}

// --------------------------------------------------------------------- Math

void _math(Vm vm) {
  final n = vm.natives;
  const c = 'java/lang/Math';
  n['$c.abs(I)I'] = (vm, t, a) => (a[0] as int).abs().toSigned(32);
  n['$c.abs(J)J'] = (vm, t, a) => (a[0] as int).abs();
  n['$c.abs(D)D'] = (vm, t, a) => (a[0] as double).abs();
  n['$c.abs(F)F'] = (vm, t, a) => (a[0] as double).abs();
  n['$c.min(II)I'] = (vm, t, a) => math.min(a[0] as int, a[1] as int);
  n['$c.max(II)I'] = (vm, t, a) => math.max(a[0] as int, a[1] as int);
  n['$c.min(JJ)J'] = (vm, t, a) => math.min(a[0] as int, a[1] as int);
  n['$c.max(JJ)J'] = (vm, t, a) => math.max(a[0] as int, a[1] as int);
  n['$c.min(DD)D'] = (vm, t, a) => math.min(a[0] as double, a[1] as double);
  n['$c.max(DD)D'] = (vm, t, a) => math.max(a[0] as double, a[1] as double);
  n['$c.sqrt(D)D'] = (vm, t, a) => math.sqrt(a[0] as double);
  n['$c.sin(D)D'] = (vm, t, a) => math.sin(a[0] as double);
  n['$c.cos(D)D'] = (vm, t, a) => math.cos(a[0] as double);
  n['$c.tan(D)D'] = (vm, t, a) => math.tan(a[0] as double);
  n['$c.floor(D)D'] = (vm, t, a) => (a[0] as double).floorToDouble();
  n['$c.ceil(D)D'] = (vm, t, a) => (a[0] as double).ceilToDouble();
  n['$c.round(F)I'] = (vm, t, a) => d2i(((a[0] as double) + 0.5).floorToDouble());
  n['$c.round(D)J'] = (vm, t, a) => d2l(((a[0] as double) + 0.5).floorToDouble());
}

// ------------------------------------------------------- System et PrintStream

void _system(Vm vm) {
  final n = vm.natives;
  const c = 'java/lang/System';
  final sys = vm.classes[c]!;
  final psClass = vm.classes['java/io/PrintStream']!;
  sys.statics['out'] = JObject(psClass);
  sys.statics['err'] = JObject(psClass);

  n['$c.currentTimeMillis()J'] = (vm, t, a) => DateTime.now().millisecondsSinceEpoch;
  n['$c.gc()V'] = (vm, t, a) => null;
  n['$c.identityHashCode(Ljava/lang/Object;)I'] =
      (vm, t, a) => identityHashCode(a[0]) & 0x7FFFFFFF;
  n['$c.getProperty(Ljava/lang/String;)Ljava/lang/String;'] = (vm, t, a) {
    switch (a[0]) {
      case 'microedition.platform':
        return vm.intern('J2ME-Dart');
      case 'microedition.encoding':
        return vm.intern('UTF-8');
      case 'microedition.configuration':
        return vm.intern('CLDC-1.1');
      case 'microedition.profiles':
        return vm.intern('MIDP-2.0');
      default:
        return null;
    }
  };
  n['$c.exit(I)V'] = (vm, t, a) {
    vm.log('System.exit(${a[0]})');
    vm.onExit?.call();
    t.done = true;
    return null;
  };
  n['$c.arraycopy(Ljava/lang/Object;ILjava/lang/Object;II)V'] = (vm, t, a) {
    if (a[0] == null || a[2] == null) throw JavaThrow('java/lang/NullPointerException');
    final src = a[0] as JArray;
    final dst = a[2] as JArray;
    final sp = a[1] as int;
    final dp = a[3] as int;
    final len = a[4] as int;
    if (sp < 0 || dp < 0 || len < 0 || sp + len > src.length || dp + len > dst.length) {
      throw JavaThrow('java/lang/ArrayIndexOutOfBoundsException', 'arraycopy');
    }
    dst.data.setRange(dp, dp + len, src.data, sp);
    return null;
  };

  const ps = 'java/io/PrintStream';
  _printTypes.forEach((desc, kind) {
    n['$ps.println($desc)V'] = (vm, t, a) {
      vm.log('[jeu] ${_conv(vm, kind, a[1])}');
      return null;
    };
    n['$ps.print($desc)V'] = (vm, t, a) {
      vm.log('[jeu] ${_conv(vm, kind, a[1])}');
      return null;
    };
  });
  n['$ps.println()V'] = (vm, t, a) => null;
}

// ---------------------------------------------------------------- Throwable

void _throwable(Vm vm) {
  final n = vm.natives;
  const c = 'java/lang/Throwable';
  String describe(JObject o) {
    final m = o.fields['message'];
    final name = o.cls.name.replaceAll('/', '.');
    return m == null ? name : '$name: $m';
  }

  n['$c.<init>()V'] = (vm, t, a) => null;
  n['$c.<init>(Ljava/lang/String;)V'] = (vm, t, a) {
    (a[0] as JObject).fields['message'] = a[1];
    return null;
  };
  n['$c.getMessage()Ljava/lang/String;'] = (vm, t, a) => (a[0] as JObject).fields['message'];
  n['$c.toString()Ljava/lang/String;'] = (vm, t, a) => describe(a[0] as JObject);
  n['$c.printStackTrace()V'] = (vm, t, a) {
    vm.log('[jeu] ${describe(a[0] as JObject)}');
    return null;
  };
}

// ------------------------------------------------------------------- Thread

void _thread(Vm vm) {
  final n = vm.natives;
  const c = 'java/lang/Thread';
  final threadClass = vm.classes[c]!;

  n['$c.<init>()V'] = (vm, t, a) => null;
  n['$c.<init>(Ljava/lang/Runnable;)V'] = (vm, t, a) {
    (a[0] as JObject).native = a[1];
    return null;
  };
  n['$c.run()V'] = (vm, t, a) => null;
  n['$c.start()V'] = (vm, t, a) {
    final th = a[0] as JObject;
    var m = vm.findMethod(th.cls, 'run', '()V');
    Object recv = th;
    if (m == null || m.native != null) {
      final target = th.native;
      if (target is! JObject) return null;
      m = vm.findMethod(target.cls, 'run', '()V');
      recv = target;
    }
    if (m == null || m.native != null) return null;
    vm.spawn('Thread-${vm.threads.length}', m, [recv]).threadObject = th;
    return null;
  };
  n['$c.sleep(J)V'] = (vm, t, a) {
    final ms = a[0] as int;
    t.wakeAt = vm.nowMs + (ms < 1 ? 1 : ms);
    t.yielding = true;
    return null;
  };
  n['$c.yield()V'] = (vm, t, a) {
    t.yielding = true;
    return null;
  };
  n['$c.join()V'] = (vm, t, a) {
    t.wakeAt = vm.nowMs + 5;
    t.yielding = true;
    return null;
  };
  n['$c.currentThread()Ljava/lang/Thread;'] =
      (vm, t, a) => t.threadObject ??= JObject.withDefaults(threadClass);
  n['$c.setPriority(I)V'] = (vm, t, a) => null;
  n['$c.interrupt()V'] = (vm, t, a) => null;
  n['$c.isAlive()Z'] = (vm, t, a) => 1;
}

// ------------------------------------------------------------------- Random

class _JRandom {
  _JRandom(int seed) {
    setSeed(seed);
  }

  static const int _mask = (1 << 48) - 1;
  int _seed = 0;

  void setSeed(int s) => _seed = (s ^ 0x5DEECE66D) & _mask;

  int next(int bits) {
    _seed = (_seed * 0x5DEECE66D + 0xB) & _mask;
    return (_seed >> (48 - bits)).toSigned(32);
  }

  int nextInt(int bound) {
    if ((bound & -bound) == bound) return (bound * next(31)) >> 31;
    int bits;
    int val;
    do {
      bits = next(31);
      val = bits % bound;
    } while (bits - val + (bound - 1) >= 0x80000000);
    return val;
  }
}

void _random(Vm vm) {
  final n = vm.natives;
  const c = 'java/util/Random';
  _JRandom r(List<Object?> a) => (a[0] as JObject).native as _JRandom;

  n['$c.<init>()V'] = (vm, t, a) {
    (a[0] as JObject).native = _JRandom(DateTime.now().microsecondsSinceEpoch);
    return null;
  };
  n['$c.<init>(J)V'] = (vm, t, a) {
    (a[0] as JObject).native = _JRandom(a[1] as int);
    return null;
  };
  n['$c.setSeed(J)V'] = (vm, t, a) {
    r(a).setSeed(a[1] as int);
    return null;
  };
  n['$c.nextInt()I'] = (vm, t, a) => r(a).next(32);
  n['$c.nextInt(I)I'] = (vm, t, a) {
    final b = a[1] as int;
    if (b <= 0) throw JavaThrow('java/lang/IllegalArgumentException', 'bound must be positive');
    return r(a).nextInt(b);
  };
  n['$c.nextLong()J'] = (vm, t, a) => (r(a).next(32) << 32) + r(a).next(32);
}

// ------------------------------------------------------------------- Vector

void _vector(Vm vm) {
  final n = vm.natives;
  const c = 'java/util/Vector';
  List<Object?> v(List<Object?> a) => (a[0] as JObject).native as List<Object?>;
  void check(List<Object?> list, int i) {
    if (i < 0 || i >= list.length) {
      throw JavaThrow('java/lang/ArrayIndexOutOfBoundsException', '$i >= ${list.length}');
    }
  }

  int indexOf(Vm vm, List<Object?> list, Object? o) {
    for (var i = 0; i < list.length; i++) {
      if (vm.javaEquals(list[i], o)) return i;
    }
    return -1;
  }

  Object? init(Vm vm, JThread t, List<Object?> a) {
    (a[0] as JObject).native = <Object?>[];
    return null;
  }
  n['$c.<init>()V'] = init;
  n['$c.<init>(I)V'] = init;
  n['$c.<init>(II)V'] = init;
  n['$c.addElement(Ljava/lang/Object;)V'] = (vm, t, a) {
    v(a).add(a[1]);
    return null;
  };
  n['$c.elementAt(I)Ljava/lang/Object;'] = (vm, t, a) {
    final list = v(a);
    check(list, a[1] as int);
    return list[a[1] as int];
  };
  n['$c.size()I'] = (vm, t, a) => v(a).length;
  n['$c.isEmpty()Z'] = (vm, t, a) => v(a).isEmpty ? 1 : 0;
  n['$c.removeAllElements()V'] = (vm, t, a) {
    v(a).clear();
    return null;
  };
  n['$c.removeElementAt(I)V'] = (vm, t, a) {
    final list = v(a);
    check(list, a[1] as int);
    list.removeAt(a[1] as int);
    return null;
  };
  n['$c.insertElementAt(Ljava/lang/Object;I)V'] = (vm, t, a) {
    final list = v(a);
    final i = a[2] as int;
    if (i < 0 || i > list.length) {
      throw JavaThrow('java/lang/ArrayIndexOutOfBoundsException', '$i');
    }
    list.insert(i, a[1]);
    return null;
  };
  n['$c.setElementAt(Ljava/lang/Object;I)V'] = (vm, t, a) {
    final list = v(a);
    check(list, a[2] as int);
    list[a[2] as int] = a[1];
    return null;
  };
  n['$c.removeElement(Ljava/lang/Object;)Z'] = (vm, t, a) {
    final list = v(a);
    final i = indexOf(vm, list, a[1]);
    if (i < 0) return 0;
    list.removeAt(i);
    return 1;
  };
  n['$c.indexOf(Ljava/lang/Object;)I'] = (vm, t, a) => indexOf(vm, v(a), a[1]);
  n['$c.contains(Ljava/lang/Object;)Z'] =
      (vm, t, a) => indexOf(vm, v(a), a[1]) >= 0 ? 1 : 0;
  n['$c.firstElement()Ljava/lang/Object;'] = (vm, t, a) {
    final list = v(a);
    if (list.isEmpty) throw JavaThrow('java/util/NoSuchElementException');
    return list.first;
  };
  n['$c.lastElement()Ljava/lang/Object;'] = (vm, t, a) {
    final list = v(a);
    if (list.isEmpty) throw JavaThrow('java/util/NoSuchElementException');
    return list.last;
  };
  n['$c.copyInto([Ljava/lang/Object;)V'] = (vm, t, a) {
    final list = v(a);
    final dst = a[1] as JArray;
    for (var i = 0; i < list.length; i++) {
      dst.data[i] = list[i];
    }
    return null;
  };
}

// ------------------------------------------------------------------- MIDlet

void _midlet(Vm vm) {
  final n = vm.natives;
  const c = 'javax/microedition/midlet/MIDlet';
  n['$c.<init>()V'] = (vm, t, a) => null;
  n['$c.notifyDestroyed()V'] = (vm, t, a) {
    vm.log('MIDlet.notifyDestroyed()');
    vm.onExit?.call();
    return null;
  };
  n['$c.notifyPaused()V'] = (vm, t, a) => null;
  n['$c.resumeRequest()V'] = (vm, t, a) => null;
  n['$c.getAppProperty(Ljava/lang/String;)Ljava/lang/String;'] = (vm, t, a) {
    final v = vm.jar.manifest[a[1] as String];
    return v == null ? null : vm.intern(v);
  };
}
