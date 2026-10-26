import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../j2me/emulator_session.dart';
import '../j2me/jar_loader.dart';
import '../theme.dart';
import 'player_screen.dart';
import 'widgets/glass.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  JarPackage? _pkg;
  String? _error;
  int _selected = 0;
  bool _loading = false;

  Future<void> _pick() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (res == null) {
        setState(() => _loading = false);
        return;
      }
      final bytes = res.files.single.bytes;
      if (bytes == null) {
        throw const FormatException('Impossible de lire ce fichier.');
      }
      final pkg = JarPackage.fromBytes(bytes);
      if (pkg.midlets.isEmpty) {
        throw const FormatException('Aucun MIDlet déclaré dans le manifeste.');
      }
      setState(() {
        _pkg = pkg;
        _selected = 0;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e is FormatException ? e.message : 'Ouverture impossible : $e';
        _loading = false;
      });
    }
  }

  void _launch() {
    final pkg = _pkg!;
    final session = EmulatorSession(pkg, pkg.midlets[_selected]);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PlayerScreen(session: session)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Backdrop(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      const Text(
                        'Pixel',
                        style: TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.5,
                        ),
                      ),
                      Text(
                        'Box',
                        style: TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.w300,
                          letterSpacing: -1,
                          color: Palette.accent2.withAlpha(230),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Tes vieux jeux Java, sur ton iPhone.',
                    style: TextStyle(fontSize: 16, color: Palette.muted),
                  ),
                  const SizedBox(height: 32),
                  Expanded(
                    child: _pkg == null
                        ? Align(alignment: Alignment.topCenter, child: _pickCard())
                        : SingleChildScrollView(child: _infoCard()),
                  ),
                  if (_pkg != null)
                    FilledButton(
                      onPressed: _launch,
                      style: FilledButton.styleFrom(
                        backgroundColor: Palette.accent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(58),
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      child: const Text('Lancer le jeu'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickCard() {
    return GestureDetector(
      onTap: _loading ? null : _pick,
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 44),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              if (_loading)
                const SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(strokeWidth: 3, color: Palette.accent),
                )
              else
                const Icon(Icons.folder_open_rounded, size: 48, color: Palette.accent),
              const SizedBox(height: 18),
              const Text(
                'Ouvrir un fichier .jar',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                'Depuis Fichiers, iCloud ou AirDrop',
                style: TextStyle(color: Palette.muted),
              ),
              if (_error != null) ...[
                const SizedBox(height: 18),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Palette.sunset),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoCard() {
    final p = _pkg!;
    final details = [
      if (p.vendor != null) p.vendor!,
      if (p.version != null) 'version ${p.version}',
      '${(p.sizeBytes / 1024).round()} Ko',
    ].join(', ');
    final spec = [
      if (p.configuration != null) p.configuration!,
      if (p.profile != null) p.profile!,
    ].join(' avec ');

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p.name,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(details, style: const TextStyle(color: Palette.muted)),
          if (spec.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(spec, style: const TextStyle(color: Palette.accent2)),
          ],
          const SizedBox(height: 20),
          for (var i = 0; i < p.midlets.length; i++)
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() => _selected = i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      i == _selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      color: Palette.accent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.midlets[i].name,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                          Text(
                            p.midlets[i].className,
                            style: const TextStyle(fontSize: 12, color: Palette.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _pick,
            child: const Text('Choisir un autre fichier'),
          ),
        ],
      ),
    );
  }
}
