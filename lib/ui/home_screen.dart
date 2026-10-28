import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../j2me/emulator_session.dart';
import '../j2me/jar_loader.dart';
import '../theme.dart';
import 'player_screen.dart';
import 'widgets/game_library_views.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<_LibraryGame> _games = [];
  int _selected = 0;
  int _selectedMidlet = 0;
  int _volume = 80;
  bool _startLandscape = false;
  int _gameFps = 60;
  int _screenMaxFps = 60;
  double _controlsOpacity = 0.88;
  bool _hapticsEnabled = true;
  final Map<String, GamePerformanceProfile> _gameProfiles = {};
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
    _loadScreenRefreshRate();
  }

  Future<void> _loadScreenRefreshRate() async {
    if (!Platform.isIOS) return;
    try {
      final maximum = await const MethodChannel('pixelbox/display')
          .invokeMethod<int>('maximumRefreshRate');
      if (mounted && maximum != null) setState(() => _screenMaxFps = maximum);
    } on PlatformException {
      // La limite logicielle reste disponible si la détection native échoue.
    }
  }

  Future<Directory> _gameDirectory() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/games');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _settingsFile() async {
    final root = await getApplicationSupportDirectory();
    return File('${root.path}/settings.json');
  }

  Future<void> _loadLibrary() async {
    try {
      final settingsFile = await _settingsFile();
      if (await settingsFile.exists()) {
        final data = jsonDecode(await settingsFile.readAsString())
            as Map<String, dynamic>;
        _volume = (data['volume'] as num?)?.round().clamp(0, 100) ?? 80;
        _startLandscape = data['startLandscape'] as bool? ?? false;
        _gameFps = data['gameFps'] as int? ?? 60;
        _controlsOpacity =
            (data['controlsOpacity'] as num?)?.toDouble().clamp(0.25, 1) ??
                0.88;
        _hapticsEnabled = data['hapticsEnabled'] as bool? ?? true;
        final profiles = data['gameProfiles'];
        if (profiles is Map) {
          for (final entry in profiles.entries) {
            _gameProfiles[entry.key.toString()] = GamePerformanceProfile.values
                .firstWhere((profile) => profile.name == entry.value,
                    orElse: () => GamePerformanceProfile.adaptive);
          }
        }
      }
      final dir = await _gameDirectory();
      final jars = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.jar'))
          .toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      for (final file in jars) {
        try {
          final pkg = JarPackage.fromBytes(await file.readAsBytes());
          if (pkg.midlets.isNotEmpty) _games.add(_LibraryGame(file, pkg));
        } catch (_) {
          // Ignore incomplete/corrupt library entries; they can be removed in Settings.
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(
            () => _error = 'Chargement de la bibliothèque impossible : $e');
      }
    }
  }

  Future<void> _saveSettings() async {
    final file = await _settingsFile();
    await file.writeAsString(jsonEncode({
      'volume': _volume,
      'startLandscape': _startLandscape,
      'gameFps': _gameFps,
      'controlsOpacity': _controlsOpacity,
      'hapticsEnabled': _hapticsEnabled,
      'gameProfiles':
          _gameProfiles.map((key, value) => MapEntry(key, value.name)),
    }));
  }

  Future<void> _pick() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jar'],
        withData: true,
      );
      if (res == null) return;
      final picked = res.files.single;
      final bytes = picked.bytes;
      if (bytes == null) {
        throw const FormatException('Impossible de lire ce fichier.');
      }
      final pkg = JarPackage.fromBytes(bytes);
      if (pkg.midlets.isEmpty) {
        throw const FormatException('Aucun MIDlet déclaré dans le manifeste.');
      }
      final dir = await _gameDirectory();
      final safeName = picked.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final destination = File(
          '${dir.path}/${DateTime.now().microsecondsSinceEpoch}_$safeName');
      await destination.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() {
        _games.add(_LibraryGame(destination, pkg));
        _selected = _games.length - 1;
        _selectedMidlet = 0;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            e is FormatException ? e.message : 'Import impossible : $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _launch() {
    final game = _games[_selected];
    final session = EmulatorSession(
        game.package, game.package.midlets[_selectedMidlet],
        audioVolume: _volume,
        startLandscape: _startLandscape,
        gameFps: _gameFps,
        controlsOpacity: _controlsOpacity,
        hapticsEnabled: _hapticsEnabled,
        performanceProfile:
            _gameProfiles[_gameKey(game)] ?? GamePerformanceProfile.adaptive);
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => PlayerScreen(session: session),
    ));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => _SettingsScreen(
        volume: _volume,
        startLandscape: _startLandscape,
        gameFps: _gameFps,
        controlsOpacity: _controlsOpacity,
        hapticsEnabled: _hapticsEnabled,
        screenMaxFps: _screenMaxFps,
        onChange: (volume, landscape, fps, opacity, haptics) async {
          setState(() {
            _volume = volume;
            _startLandscape = landscape;
            _gameFps = fps;
            _controlsOpacity = opacity;
            _hapticsEnabled = haptics;
          });
          await _saveSettings();
        },
        onRemove: (game) async {
          await game.file.delete();
          if (!mounted) return;
          setState(() {
            _games.remove(game);
            _gameProfiles.remove(_gameKey(game));
            if (_games.isEmpty) {
              _selected = 0;
            } else {
              _selected = _selected.clamp(0, _games.length - 1);
            }
            _selectedMidlet = 0;
          });
        },
        games: List.unmodifiable(_games),
        gameProfiles: Map.unmodifiable(_gameProfiles),
        onProfileChanged: (game, profile) async {
          setState(() => _gameProfiles[_gameKey(game)] = profile);
          await _saveSettings();
        },
      ),
    ));
  }

  String _gameKey(_LibraryGame game) => game.file.uri.pathSegments.last;

  @override
  Widget build(BuildContext context) {
    final selectedGame = _games.isEmpty ? null : _games[_selected];
    return Scaffold(
      backgroundColor: Palette.bg,
      body: Stack(
        children: [
          Positioned.fill(child: _backdrop(selectedGame)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(),
                  const SizedBox(height: 30),
                  _libraryHeading(),
                  if (_loading) ...[
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                  if (_error != null && _games.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      _error!,
                      style: const TextStyle(color: Palette.sunset),
                    ),
                  ],
                  const SizedBox(height: 4),
                  if (_games.isEmpty)
                    Expanded(child: _empty())
                  else ...[
                    Expanded(
                      child: GameShelf(
                        itemCount: _games.length,
                        selectedIndex: _selected,
                        onSelected: (index) => setState(() {
                          _selected = index;
                          _selectedMidlet = 0;
                        }),
                        itemBuilder: (context, index, width, onTap) => _cover(
                          _games[index],
                          index,
                          width: width,
                          onTap: onTap,
                        ),
                      ),
                    ),
                    if (selectedGame != null) ...[
                      const SizedBox(height: 10),
                      _selectedPanel(selectedGame),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _backdrop(_LibraryGame? game) {
    final bytes = game == null ? null : _iconBytes(game);
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF14233D), Palette.bg, Color(0xFF080C16)],
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 450),
          child: bytes == null
              ? SizedBox.expand(
                  key: ValueKey(game?.file.path ?? 'no-game-art'),
                )
              : ImageFiltered(
                  key: ValueKey(game!.file.path),
                  imageFilter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: Transform.scale(
                    scale: 1.18,
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      cacheWidth: 700,
                      errorBuilder: (_, __, ___) => const SizedBox.expand(),
                    ),
                  ),
                ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xD8070B14),
                Color(0x74070B14),
                Color(0xC8070B14),
                Color(0xF4070B14),
              ],
              stops: [0, 0.30, 0.64, 1],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.95, -0.8),
              radius: 1.1,
              colors: [Color(0x353A72C7), Color(0x00070B14)],
            ),
          ),
        ),
      ],
    );
  }

  Uint8List? _iconBytes(_LibraryGame game) {
    final icon = game.package.midlets.first.icon;
    if (icon == null) return null;
    return game.package.files[icon.replaceFirst(RegExp(r'^/'), '')];
  }

  Widget _header() => Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withAlpha(28)),
            ),
            child: const Icon(CupertinoIcons.game_controller_solid,
                color: Palette.accent, size: 22),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: RichText(
              text: const TextSpan(
                style: TextStyle(fontSize: 21, letterSpacing: 1.3),
                children: [
                  TextSpan(
                    text: 'PIXEL',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  TextSpan(
                    text: 'BOX',
                    style: TextStyle(
                      color: Palette.accent,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _navChip('JEUX', selected: true),
          const SizedBox(width: 8),
          _headerAction(Icons.settings_rounded, 'Réglages', _openSettings),
          const SizedBox(width: 7),
          _headerAction(
            Icons.add_rounded,
            'Importer un jeu',
            _loading ? null : _pick,
            highlighted: true,
          ),
        ],
      );

  Widget _navChip(String label, {bool selected = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.white.withAlpha(15) : Colors.transparent,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: selected ? Palette.accent.withAlpha(90) : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Palette.accent : Palette.muted,
            fontSize: 10,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w800,
          ),
        ),
      );

  Widget _headerAction(IconData icon, String tooltip, VoidCallback? onPressed,
          {bool highlighted = false}) =>
      Tooltip(
        message: tooltip,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(highlighted ? 18 : 10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: highlighted
                  ? Palette.accent.withAlpha(100)
                  : Colors.white.withAlpha(26),
            ),
          ),
          child: IconButton(
            onPressed: onPressed,
            icon: Icon(icon,
                color: highlighted ? Palette.accent : Palette.text, size: 20),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );

  Widget _libraryHeading() => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'BIBLIOTHÈQUE DE JEUX',
                  style: TextStyle(
                    color: Palette.accent,
                    fontSize: 10,
                    letterSpacing: 2.3,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _games.isEmpty ? 'Prêt à jouer ?' : 'Ta collection',
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.7,
                  ),
                ),
              ],
            ),
          ),
          if (_games.isNotEmpty)
            Text(
              '${_games.length.toString().padLeft(2, '0')} JEUX',
              style: const TextStyle(
                color: Palette.muted,
                fontSize: 10,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      );

  Widget _empty() => Center(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(26),
          decoration: BoxDecoration(
            color: Palette.surface.withAlpha(180),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Palette.outline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Palette.accent.withAlpha(18),
                  border: Border.all(color: Palette.accent.withAlpha(70)),
                ),
                child: const Icon(Icons.sports_esports_rounded,
                    color: Palette.accent, size: 34),
              ),
              const SizedBox(height: 20),
              const Text(
                'Ta collection commence ici',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? 'Ajoute un jeu Java ME pour remplir ta bibliothèque.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.muted, height: 1.4),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: _loading ? null : _pick,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Importer un jeu'),
              ),
            ],
          ),
        ),
      );

  Widget _selectedPanel(_LibraryGame game) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            const Icon(Icons.play_arrow_rounded,
                color: Palette.accent, size: 17),
            const SizedBox(width: 5),
            Text(
              'JEU ${(_selected + 1).toString().padLeft(2, '0')} · SÉLECTIONNÉ',
              style: const TextStyle(
                color: Palette.accent,
                fontSize: 10,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            game.package.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 27,
              height: 1.05,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.65,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${game.package.vendor ?? 'Java ME'}  ·  ${game.package.version ?? 'MIDP'}  ·  ${(game.package.sizeBytes / 1024).round()} Ko',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Palette.muted, fontSize: 12),
          ),
          if (game.package.midlets.length > 1) ...[
            const SizedBox(height: 5),
            SizedBox(
              height: 38,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _selectedMidlet.clamp(
                    0,
                    game.package.midlets.length - 1,
                  ),
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: Palette.surfaceRaised,
                  items: [
                    for (var i = 0; i < game.package.midlets.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                          game.package.midlets[i].name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _selectedMidlet = value ?? 0),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: _launch,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Jouer maintenant'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Palette.text,
                    foregroundColor: Palette.bg,
                    alignment: Alignment.center,
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 52,
              height: 52,
              child: OutlinedButton(
                onPressed: _loading ? null : _pick,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Palette.text,
                  side: BorderSide(color: Colors.white.withAlpha(70)),
                  padding: EdgeInsets.zero,
                ),
                child: const Icon(Icons.add_rounded),
              ),
            ),
          ]),
        ],
      );

  Widget _cover(
    _LibraryGame game,
    int index, {
    double width = 150,
    required VoidCallback onTap,
  }) {
    final selected = index == _selected;
    final iconBytes = game.package.midlets.first.icon == null
        ? null
        : game.package.files[
            game.package.midlets.first.icon!.replaceFirst(RegExp(r'^/'), '')];
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: 0.72,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: width,
          decoration: BoxDecoration(
              color: const Color(0xFF18202C),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: selected ? Palette.accent : Colors.white12,
                  width: selected ? 2 : 1),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: Palette.accent.withAlpha(65),
                        blurRadius: 26,
                        spreadRadius: 1,
                      ),
                    ]
                  : const []),
          clipBehavior: Clip.antiAlias,
          child: Stack(fit: StackFit.expand, children: [
            if (iconBytes != null)
              Image.memory(iconBytes,
                  fit: BoxFit.cover,
                  cacheWidth: (width * pixelRatio).round(),
                  cacheHeight: (width / 0.72 * pixelRatio).round(),
                  errorBuilder: (_, __, ___) => _coverTitle(game.package.name))
            else
              _coverTitle(game.package.name),
            Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                    height: 62,
                    decoration: const BoxDecoration(
                        gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black87])),
                    alignment: Alignment.bottomLeft,
                    padding: const EdgeInsets.all(11),
                    child: Text(game.package.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700)))),
          ]),
        ),
      ),
    );
  }

  Widget _coverTitle(String title) => Container(
      color: const Color(0xFF202B3A),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(14),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(CupertinoIcons.game_controller_solid,
            size: 42, color: Palette.accent),
        const SizedBox(height: 12),
        Text(title,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ]));
}

class _LibraryGame {
  const _LibraryGame(this.file, this.package);
  final File file;
  final JarPackage package;
}

class _SettingsScreen extends StatefulWidget {
  const _SettingsScreen({
    required this.volume,
    required this.startLandscape,
    required this.gameFps,
    required this.controlsOpacity,
    required this.hapticsEnabled,
    required this.screenMaxFps,
    required this.games,
    required this.gameProfiles,
    required this.onProfileChanged,
    required this.onChange,
    required this.onRemove,
  });
  final int volume;
  final bool startLandscape;
  final int gameFps;
  final double controlsOpacity;
  final bool hapticsEnabled;
  final int screenMaxFps;
  final List<_LibraryGame> games;
  final Map<String, GamePerformanceProfile> gameProfiles;
  final Future<void> Function(_LibraryGame, GamePerformanceProfile)
      onProfileChanged;
  final Future<void> Function(int, bool, int, double, bool) onChange;
  final Future<void> Function(_LibraryGame) onRemove;
  @override
  State<_SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<_SettingsScreen> {
  late int _volume = widget.volume;
  late bool _landscape = widget.startLandscape;
  late int _fps = widget.gameFps;
  late double _controlsOpacity = widget.controlsOpacity;
  late bool _hapticsEnabled = widget.hapticsEnabled;
  late final List<_LibraryGame> _games = [...widget.games];
  late final Map<String, GamePerformanceProfile> _profiles =
      Map.of(widget.gameProfiles);

  List<int> get _availableFps =>
      [30, 60, 90, 120].where((rate) => rate <= widget.screenMaxFps).toList();

  Future<void> _update() => widget.onChange(
        _volume,
        _landscape,
        _fps,
        _controlsOpacity,
        _hapticsEnabled,
      );

  Widget _section(String title, IconData icon, Widget child) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Palette.surface.withAlpha(225),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Palette.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: Palette.accent, size: 19),
              const SizedBox(width: 9),
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 16),
            child,
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Palette.bg,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF111C31), Palette.bg, Color(0xFF090D17)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                  child: Row(children: [
                    IconButton.filledTonal(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Réglages',
                              style: TextStyle(
                                  fontSize: 24, fontWeight: FontWeight.w700)),
                          Text('PERSONNALISE TON EXPÉRIENCE',
                              style: TextStyle(
                                  color: Palette.muted,
                                  fontSize: 9,
                                  letterSpacing: 1.3,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                    const Icon(Icons.tune_rounded, color: Palette.accent),
                  ]),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
                    children: [
                      _section(
                        'Audio',
                        Icons.volume_up_rounded,
                        Column(
                          children: [
                            Row(children: [
                              const Expanded(child: Text('Volume des jeux')),
                              Text('$_volume %',
                                  style: const TextStyle(
                                      color: Palette.accent,
                                      fontWeight: FontWeight.w700)),
                            ]),
                            Slider(
                              value: _volume.toDouble(),
                              min: 0,
                              max: 100,
                              divisions: 20,
                              onChanged: (value) {
                                setState(() => _volume = value.round());
                                _update();
                              },
                            ),
                          ],
                        ),
                      ),
                      _section(
                        'Émulation et affichage',
                        Icons.speed_rounded,
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Cadence du jeu',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final fps in _availableFps)
                                  ChoiceChip(
                                    label: Text('$fps IPS'),
                                    selected: _fps == fps,
                                    onSelected: (_) {
                                      setState(() => _fps = fps);
                                      _update();
                                    },
                                  ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Palette.bg.withAlpha(150),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Row(children: [
                                const Icon(Icons.display_settings_rounded,
                                    color: Palette.accent, size: 19),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          'Écran détecté · jusqu’à ${widget.screenMaxFps} Hz',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 3),
                                      const Text(
                                          'iOS adapte le rafraîchissement matériel automatiquement.',
                                          style: TextStyle(
                                              color: Palette.muted,
                                              fontSize: 11)),
                                    ],
                                  ),
                                ),
                              ]),
                            ),
                            const SizedBox(height: 12),
                            _switchRow(
                              title: 'Démarrer en paysage',
                              subtitle: 'Appliqué au prochain lancement',
                              value: _landscape,
                              onChanged: (value) {
                                setState(() => _landscape = value);
                                _update();
                              },
                            ),
                          ],
                        ),
                      ),
                      _section(
                        'Commandes tactiles',
                        Icons.gamepad_rounded,
                        Column(
                          children: [
                            _switchRow(
                              title: 'Retour haptique',
                              subtitle: 'Vibre lors des appuis sur le gamepad',
                              value: _hapticsEnabled,
                              onChanged: (value) {
                                setState(() => _hapticsEnabled = value);
                                _update();
                              },
                            ),
                            const SizedBox(height: 12),
                            Row(children: [
                              const Expanded(
                                  child: Text('Visibilité du gamepad')),
                              Text('${(_controlsOpacity * 100).round()} %',
                                  style: const TextStyle(
                                      color: Palette.accent,
                                      fontWeight: FontWeight.w700)),
                            ]),
                            Slider(
                              value: _controlsOpacity,
                              min: 0.25,
                              max: 1,
                              divisions: 15,
                              onChanged: (value) {
                                setState(() => _controlsOpacity = value);
                                _update();
                              },
                            ),
                          ],
                        ),
                      ),
                      _section(
                        'Bibliothèque · ${_games.length}',
                        Icons.video_library_rounded,
                        _games.isEmpty
                            ? const Text('Aucun jeu importé.',
                                style: TextStyle(color: Palette.muted))
                            : Column(
                                children: [
                                  for (final game in _games) _libraryTile(game),
                                ],
                              ),
                      ),
                      Center(
                        child: Text(
                          'PIXELBOX  ·  ÉMULATEUR JAVA ME',
                          style: TextStyle(
                            color: Palette.muted.withAlpha(180),
                            fontSize: 10,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _switchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(subtitle,
                    style: const TextStyle(color: Palette.muted, fontSize: 11)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      );

  Widget _libraryTile(_LibraryGame game) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Palette.bg.withAlpha(130),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          const Icon(Icons.sports_esports_rounded,
              color: Palette.accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(game.package.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(game.file.uri.pathSegments.last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Palette.muted, fontSize: 10)),
                Text(
                    'Profil · ${(_profiles[game.file.uri.pathSegments.last] ?? GamePerformanceProfile.adaptive).label}',
                    style:
                        const TextStyle(color: Palette.accent, fontSize: 10)),
              ],
            ),
          ),
          PopupMenuButton<GamePerformanceProfile>(
            tooltip: 'Profil de performance',
            initialValue: _profiles[game.file.uri.pathSegments.last] ??
                GamePerformanceProfile.adaptive,
            onSelected: (profile) async {
              setState(
                  () => _profiles[game.file.uri.pathSegments.last] = profile);
              await widget.onProfileChanged(game, profile);
            },
            itemBuilder: (_) => [
              for (final profile in GamePerformanceProfile.values)
                PopupMenuItem(
                  value: profile,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(profile.label),
                      Text(profile.description,
                          style: const TextStyle(
                              color: Palette.muted, fontSize: 10)),
                    ],
                  ),
                ),
            ],
            icon: const Icon(Icons.tune_rounded, color: Palette.accent),
          ),
          IconButton(
            tooltip: 'Supprimer le jeu',
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Supprimer ce jeu ?'),
                  content:
                      Text('« ${game.package.name} » sera retiré de PixelBox.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Annuler'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Supprimer'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              await widget.onRemove(game);
              if (mounted) setState(() => _games.remove(game));
            },
            icon:
                const Icon(Icons.delete_outline_rounded, color: Palette.blood),
          ),
        ]),
      );
}
