import 'dart:typed_data';

/// Entrée du constant pool.
/// - Utf8 (1) : value = String
/// - Integer (3) / Long (5) : value = int ; Float (4) / Double (6) : value = double
/// - Class (7) / String (8) : a = index
/// - Fieldref/Methodref/InterfaceMethodref (9/10/11) : a = classe, b = NameAndType
/// - NameAndType (12) : a = nom, b = descripteur
class CpEntry {
  const CpEntry(this.tag, {this.value, this.a = 0, this.b = 0});

  final int tag;
  final Object? value;
  final int a;
  final int b;
}

class ExceptionEntry {
  const ExceptionEntry(this.startPc, this.endPc, this.handlerPc, this.catchType);

  final int startPc;
  final int endPc;
  final int handlerPc;
  final int catchType;
}

class CodeAttr {
  const CodeAttr(this.maxStack, this.maxLocals, this.code, this.exceptions);

  final int maxStack;
  final int maxLocals;
  final Uint8List code;
  final List<ExceptionEntry> exceptions;
}

class MemberInfo {
  const MemberInfo(
    this.access,
    this.name,
    this.descriptor,
    this.code,
    this.constantValueIndex,
  );

  final int access;
  final String name;
  final String descriptor;
  final CodeAttr? code;
  final int constantValueIndex;

  bool get isStatic => access & 0x0008 != 0;
  bool get isNative => access & 0x0100 != 0;
  bool get isAbstract => access & 0x0400 != 0;
}

class ClassFile {
  ClassFile._({
    required this.major,
    required this.constantPool,
    required this.accessFlags,
    required this.thisClass,
    required this.superClass,
    required this.interfaces,
    required this.fields,
    required this.methods,
  });

  final int major;
  final List<CpEntry?> constantPool;
  final int accessFlags;
  final String thisClass;
  final String? superClass;
  final List<String> interfaces;
  final List<MemberInfo> fields;
  final List<MemberInfo> methods;

  String utf8At(int i) => constantPool[i]!.value as String;
  String classNameAt(int i) => utf8At(constantPool[i]!.a);

  MemberInfo? findMethod(String name, String descriptor) {
    for (final m in methods) {
      if (m.name == name && m.descriptor == descriptor) return m;
    }
    return null;
  }

  static ClassFile parse(Uint8List bytes) {
    final r = _Reader(bytes);

    if (r.u4() != 0xCAFEBABE) {
      throw const FormatException("Ce n'est pas un fichier .class.");
    }
    r.u2(); // minor
    final major = r.u2();

    final count = r.u2();
    final cp = List<CpEntry?>.filled(count, null);
    for (var i = 1; i < count; i++) {
      final tag = r.u1();
      switch (tag) {
        case 1:
          cp[i] = CpEntry(1, value: _decodeMutf8(r.take(r.u2())));
        case 3:
          cp[i] = CpEntry(3, value: r.i4());
        case 4:
          cp[i] = CpEntry(4, value: r.f4());
        case 5:
          cp[i] = CpEntry(5, value: r.i8());
          i++; // Long occupe deux slots.
        case 6:
          cp[i] = CpEntry(6, value: r.d8());
          i++; // Double aussi.
        case 7:
        case 8:
          cp[i] = CpEntry(tag, a: r.u2());
        case 9:
        case 10:
        case 11:
        case 12:
          cp[i] = CpEntry(tag, a: r.u2(), b: r.u2());
        default:
          throw FormatException('Entrée de constant pool inconnue : $tag');
      }
    }

    String utf8At(int i) => cp[i]!.value as String;
    String classNameAt(int i) => utf8At(cp[i]!.a);

    final access = r.u2();
    final thisClass = classNameAt(r.u2());
    final superIdx = r.u2();
    final superClass = superIdx == 0 ? null : classNameAt(superIdx);

    final interfaces = <String>[];
    final ifCount = r.u2();
    for (var i = 0; i < ifCount; i++) {
      interfaces.add(classNameAt(r.u2()));
    }

    List<MemberInfo> readMembers() {
      final out = <MemberInfo>[];
      final n = r.u2();
      for (var i = 0; i < n; i++) {
        final acc = r.u2();
        final name = utf8At(r.u2());
        final desc = utf8At(r.u2());
        CodeAttr? code;
        var constantValue = 0;

        final attrCount = r.u2();
        for (var a = 0; a < attrCount; a++) {
          final attrName = utf8At(r.u2());
          final len = r.u4();
          final end = r.pos + len;
          if (attrName == 'Code') {
            final maxStack = r.u2();
            final maxLocals = r.u2();
            final bytecode = r.take(r.u4());
            final exCount = r.u2();
            final exceptions = <ExceptionEntry>[];
            for (var e = 0; e < exCount; e++) {
              exceptions.add(ExceptionEntry(r.u2(), r.u2(), r.u2(), r.u2()));
            }
            code = CodeAttr(maxStack, maxLocals, bytecode, exceptions);
          } else if (attrName == 'ConstantValue') {
            constantValue = r.u2();
          }
          r.pos = end;
        }
        out.add(MemberInfo(acc, name, desc, code, constantValue));
      }
      return out;
    }

    final fields = readMembers();
    final methods = readMembers();

    return ClassFile._(
      major: major,
      constantPool: cp,
      accessFlags: access,
      thisClass: thisClass,
      superClass: superClass,
      interfaces: interfaces,
      fields: fields,
      methods: methods,
    );
  }
}

class _Reader {
  _Reader(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  int pos = 0;

  int u1() => data.getUint8(pos++);

  int u2() {
    final v = data.getUint16(pos);
    pos += 2;
    return v;
  }

  int u4() {
    final v = data.getUint32(pos);
    pos += 4;
    return v;
  }

  int i4() {
    final v = data.getInt32(pos);
    pos += 4;
    return v;
  }

  int i8() {
    final v = data.getInt64(pos);
    pos += 8;
    return v;
  }

  double f4() {
    final v = data.getFloat32(pos);
    pos += 4;
    return v;
  }

  double d8() {
    final v = data.getFloat64(pos);
    pos += 8;
    return v;
  }

  Uint8List take(int n) {
    final s = Uint8List.sublistView(bytes, pos, pos + n);
    pos += n;
    return s;
  }
}

/// Décodage « modified UTF-8 » utilisé dans les .class.
String _decodeMutf8(Uint8List b) {
  final out = StringBuffer();
  var i = 0;
  while (i < b.length) {
    final c = b[i];
    if (c < 0x80) {
      out.writeCharCode(c);
      i++;
    } else if ((c & 0xE0) == 0xC0) {
      out.writeCharCode(((c & 0x1F) << 6) | (b[i + 1] & 0x3F));
      i += 2;
    } else {
      out.writeCharCode(
        ((c & 0x0F) << 12) | ((b[i + 1] & 0x3F) << 6) | (b[i + 2] & 0x3F),
      );
      i += 3;
    }
  }
  return out.toString();
}
