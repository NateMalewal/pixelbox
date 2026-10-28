import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'rms.dart';

class RmsStorage {
  static const _fileName = 'rms.json';

  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();

    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    return File('${directory.path}/$_fileName');
  }

  Future<void> load(RmsBackend backend) async {
    try {
      final file = await _file();

      if (!await file.exists()) {
        return;
      }

      final content = await file.readAsString();

      if (content.trim().isEmpty) {
        return;
      }

      final decoded = jsonDecode(content);

      if (decoded is Map<String, dynamic>) {
        backend.loadJson(decoded);
      }
    } catch (e) {
      // Une sauvegarde RMS corrompue ne doit pas empêcher
      // le jeu de démarrer.
      print('[RMS] Impossible de charger les sauvegardes : $e');
    }
  }

  Future<void> save(RmsBackend backend) async {
    try {
      final file = await _file();

      final json = jsonEncode(backend.toJson());

      await file.writeAsString(
        json,
        flush: true,
      );
    } catch (e) {
      print('[RMS] Impossible de sauvegarder : $e');
    }
  }
}
