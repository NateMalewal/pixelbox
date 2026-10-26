import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class MidletInfo {
  const MidletInfo(this.name, this.icon, this.className);

  final String name;
  final String? icon;
  final String className;
}

/// Un fichier .jar de jeu J2ME décompressé en mémoire.
class JarPackage {
  JarPackage._(this.files, this.manifest, this.midlets, this.sizeBytes);

  final Map<String, Uint8List> files;
  final Map<String, String> manifest;
  final List<MidletInfo> midlets;
  final int sizeBytes;

  String get name => manifest['MIDlet-Name'] ?? midlets.first.name;
  String? get vendor => manifest['MIDlet-Vendor'];
  String? get version => manifest['MIDlet-Version'];
  String? get configuration => manifest['MicroEdition-Configuration'];
  String? get profile => manifest['MicroEdition-Profile'];

  static JarPackage fromBytes(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException("Ce fichier n'est pas un .jar valide.");
    }

    final files = <String, Uint8List>{};
    for (final f in archive) {
      if (f.isFile) {
        files[f.name] = Uint8List.fromList(f.content as List<int>);
      }
    }

    final mfBytes = files['META-INF/MANIFEST.MF'];
    if (mfBytes == null) {
      throw const FormatException('MANIFEST.MF introuvable dans le .jar.');
    }
    final manifest = _parseManifest(utf8.decode(mfBytes, allowMalformed: true));

    final midlets = <MidletInfo>[];
    for (var i = 1; manifest.containsKey('MIDlet-$i'); i++) {
      final parts = manifest['MIDlet-$i']!.split(',').map((s) => s.trim()).toList();
      if (parts.length < 3) continue;
      midlets.add(MidletInfo(
        parts[0],
        parts[1].isEmpty ? null : parts[1],
        parts[2],
      ));
    }

    return JarPackage._(files, manifest, midlets, bytes.length);
  }

  static Map<String, String> _parseManifest(String text) {
    final map = <String, String>{};
    String? key;
    for (final raw in text.split(RegExp(r'\r\n|\n|\r'))) {
      if (raw.startsWith(' ') && key != null) {
        // Ligne de continuation.
        map[key] = map[key]! + raw.substring(1);
        continue;
      }
      final i = raw.indexOf(':');
      if (i <= 0) continue;
      key = raw.substring(0, i).trim();
      map[key] = raw.substring(i + 1).trim();
    }
    return map;
  }
}
