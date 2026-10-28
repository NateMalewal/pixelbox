import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../j2me/emulator_session.dart';
import '../j2me/key_codes.dart';
import '../theme.dart';
import 'widgets/dpad.dart';
import 'widgets/glass.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.session});

  final EmulatorSession session;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _landscape = false;
  bool _exitPopScheduled = false;
  bool _showDiagnostics = false;

  EmulatorSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    s.exited.addListener(_onSessionExit);
    s.boot();
    _landscape = s.startLandscape;
    SystemChrome.setPreferredOrientations(
      _landscape
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight
            ]
          : const [DeviceOrientation.portraitUp],
    );
  }

  @override
  void dispose() {
    s.exited.removeListener(_onSessionExit);
    s.dispose();
    SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp],
    );
    super.dispose();
  }

  void _onSessionExit() {
    if (!s.exited.value || _exitPopScheduled) return;
    _exitPopScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    });
  }

  void _leaveGame() {
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  void _setOrientation(bool landscape) {
    if (_landscape == landscape) return;

    setState(() => _landscape = landscape);

    SystemChrome.setPreferredOrientations(
      landscape
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
  }

  void _dir(J2meKey key, bool down) {
    s.key(key, down);
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: Palette.bg,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF111D32), Palette.bg, Color(0xFF090D18)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: Column(
              children: [
                _topBar(context),
                const SizedBox(height: 10),
                Expanded(
                  child: isLandscape
                      ? _landscapeLayout(context)
                      : Center(child: _screen()),
                ),
                if (!isLandscape) _controls(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _landscapeLayout(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sideWidth = math.min(220.0, constraints.maxWidth * 0.28);
        final dpadSize = math.min(170.0, constraints.maxHeight * 0.58);

        return Row(
          children: [
            SizedBox(
              width: sideWidth,
              child: Opacity(
                opacity: s.controlsOpacity,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    DPad(
                      size: dpadSize,
                      onKey: _dir,
                      hapticsEnabled: s.hapticsEnabled,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: GlassButton(
                              label: 'Menu',
                              height: 42,
                              fontSize: 14,
                              hapticsEnabled: s.hapticsEnabled,
                              onKey: (down) => s.key(J2meKey.softLeft, down),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GlassButton(
                              label: 'Retour',
                              height: 42,
                              fontSize: 14,
                              hapticsEnabled: s.hapticsEnabled,
                              onKey: (down) => s.key(J2meKey.softRight, down),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: Center(child: _screen())),
            SizedBox(
              width: sideWidth,
              child: Opacity(
                opacity: s.controlsOpacity,
                child: Center(child: _actionButtons(landscape: true)),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _topBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Palette.surface.withAlpha(220),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Palette.outline),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: _leaveGame,
            tooltip: 'Quitter le jeu',
            icon: const Icon(Icons.close_rounded),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.midlet.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Palette.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Text(
                  'SESSION J2ME ACTIVE',
                  style: TextStyle(
                    color: Palette.accent,
                    fontSize: 9,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Diagnostic de performance',
            onPressed: () =>
                setState(() => _showDiagnostics = !_showDiagnostics),
            icon: Icon(
              _showDiagnostics ? Icons.monitor_heart : Icons.speed_rounded,
              color: _showDiagnostics ? Palette.accent : Palette.text,
            ),
          ),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Portrait')),
              ButtonSegment(value: true, label: Text('Paysage')),
            ],
            selected: {_landscape},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => _setOrientation(selection.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 11)),
              foregroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                      ? Palette.bg
                      : Palette.text),
              backgroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                      ? Palette.accent
                      : Palette.surfaceRaised),
              side: WidgetStatePropertyAll(
                BorderSide(color: Palette.outline.withAlpha(180)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _screen() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
      child: AspectRatio(
        aspectRatio: EmulatorSession.width / EmulatorSession.height,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Palette.accent.withAlpha(100), width: 2),
            boxShadow: [
              BoxShadow(
                color: Palette.accent.withAlpha(24),
                blurRadius: 30,
                spreadRadius: 3,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ValueListenableBuilder<ui.Image?>(
                valueListenable: s.frame,
                builder: (context, frame, _) {
                  if (frame == null) {
                    return const Center(
                      child: CupertinoActivityIndicator(color: Palette.accent),
                    );
                  }
                  return RawImage(
                    image: frame,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.none,
                  );
                },
              ),
              Positioned(
                top: 10,
                left: 10,
                child: _displayBadge('240 × 320'),
              ),
              if (_showDiagnostics)
                Positioned(
                  top: 10,
                  right: 10,
                  child: ValueListenableBuilder<EmulatorDiagnostics>(
                    valueListenable: s.diagnostics,
                    builder: (context, stats, _) => _diagnosticsPanel(stats),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _diagnosticsPanel(EmulatorDiagnostics stats) => Container(
        constraints: const BoxConstraints(maxWidth: 190),
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(205),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Palette.outline),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(color: Palette.text, fontSize: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Rendu · ${stats.renderFps.toStringAsFixed(0)} IPS'),
              Text('VM · ${stats.averageVmMs.toStringAsFixed(1)} ms/tick'),
              Text('VM · ${stats.bytecodesPerSecond.toStringAsFixed(0)} op/s'),
              Text('Dans · ${stats.vmLocation}',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              Text(
                  'Conversion · ${stats.averageConvertMs.toStringAsFixed(1)} ms'),
              Text('Décodage · ${stats.averageDecodeMs.toStringAsFixed(1)} ms'),
              if (stats.lastImageResource.isNotEmpty)
                Text(
                  'Image · ${stats.lastImageResource} (${stats.lastImageDecodeMs.toStringAsFixed(0)} ms)',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              if (stats.vmSaturated)
                const Text('VM souvent à son budget',
                    style: TextStyle(color: Colors.orangeAccent)),
              if (stats.renderBacklog)
                const Text('Rendu en attente',
                    style: TextStyle(color: Colors.orangeAccent)),
            ],
          ),
        ),
      );

  Widget _displayBadge(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(170),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.white.withAlpha(40)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Palette.accent,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
          ),
        ),
      );

  Widget _controls(
    BuildContext context, {
    bool landscape = false,
  }) {
    return Opacity(
      opacity: s.controlsOpacity,
      child: Container(
        margin: EdgeInsets.fromLTRB(
          landscape ? 8 : 4,
          landscape ? 4 : 8,
          landscape ? 8 : 4,
          landscape ? 8 : 4,
        ),
        padding: EdgeInsets.fromLTRB(
          landscape ? 8 : 16,
          landscape ? 8 : 12,
          landscape ? 8 : 16,
          landscape ? 8 : 12,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Palette.surfaceRaised.withAlpha(235), Palette.surface],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Palette.outline),
          boxShadow: [
            BoxShadow(color: Colors.black.withAlpha(45), blurRadius: 24),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: GlassButton(
                    label: 'Menu',
                    hapticsEnabled: s.hapticsEnabled,
                    onKey: (down) => s.key(J2meKey.softLeft, down),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GlassButton(
                    label: 'Retour',
                    hapticsEnabled: s.hapticsEnabled,
                    onKey: (down) => s.key(J2meKey.softRight, down),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                DPad(
                  size: landscape ? 170 : 190,
                  onKey: _dir,
                  hapticsEnabled: s.hapticsEnabled,
                ),
                const SizedBox(width: 8),
                _actionButtons(landscape: landscape),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButtons({required bool landscape}) {
    final size = landscape ? 60.0 : 68.0;

    return SizedBox(
      width: landscape ? 132 : 140,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _actionKey(
                label: 'A',
                key: J2meKey.num5,
                size: size,
              ),
              _actionKey(
                label: 'B',
                key: J2meKey.num0,
                size: size,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'A = 5     B = 0',
            style: TextStyle(
              color: Colors.white.withAlpha(130),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionKey({
    required String label,
    required J2meKey key,
    required double size,
  }) {
    return GlassButton(
      label: label,
      circle: true,
      height: size,
      fontSize: 21,
      hapticsEnabled: s.hapticsEnabled,
      onKey: (down) => s.key(key, down),
    );
  }
}
