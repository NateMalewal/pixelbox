import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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
  /// Beaucoup de vieux jeux lisent les touches 2/4/6/8/5 au lieu des flèches.
  bool _numericDpad = false;

  EmulatorSession get s => widget.session;

  static const _numericMap = {
    J2meKey.up: J2meKey.num2,
    J2meKey.down: J2meKey.num8,
    J2meKey.left: J2meKey.num4,
    J2meKey.right: J2meKey.num6,
    J2meKey.fire: J2meKey.num5,
  };

  @override
  void initState() {
    super.initState();
    s.boot();
  }

  @override
  void dispose() {
    s.dispose();
    super.dispose();
  }

  void _dir(J2meKey k, bool down) {
    s.key(_numericDpad ? (_numericMap[k] ?? k) : k, down);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Backdrop(),
          SafeArea(
            child: Column(
              children: [
                _topBar(context),
                Expanded(child: Center(child: _screen())),
                _controls(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              s.midlet.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _numericDpad = !_numericDpad),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: Colors.white.withAlpha(16),
                border: Border.all(color: Colors.white.withAlpha(34)),
              ),
              child: Text(
                _numericDpad ? 'Touches 2 4 6 8' : 'Flèches',
                style: const TextStyle(fontSize: 13, color: Palette.accent2),
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
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withAlpha(30)),
            boxShadow: [
              BoxShadow(
                color: Palette.accent.withAlpha(90),
                blurRadius: 44,
                spreadRadius: -8,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(25),
            child: ValueListenableBuilder<ui.Image?>(
              valueListenable: s.frame,
              builder: (_, img, __) => img != null
                  ? RawImage(
                      image: img,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.none,
                    )
                  : _console(),
            ),
          ),
        ),
      ),
    );
  }

  /// Affichée tant que le moteur ne dessine rien : journal de démarrage.
  Widget _console() {
    return ValueListenableBuilder<List<String>>(
      valueListenable: s.log,
      builder: (_, lines, __) => Padding(
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final l in lines.length > 14 ? lines.sublist(lines.length - 14) : lines)
                Text(
                  l,
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 11,
                    height: 1.4,
                    color: Palette.accent2,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  label: J2meKey.softLeft.label,
                  height: 44,
                  onKey: (d) => s.key(J2meKey.softLeft, d),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GlassButton(
                  label: J2meKey.softRight.label,
                  height: 44,
                  onKey: (d) => s.key(J2meKey.softRight, d),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              DPad(size: 190, onKey: _dir),
              _rightCluster(context),
            ],
          ),
        ],
      ),
    );
  }

  Widget _numKey(J2meKey k, {double size = 62}) => GlassButton(
        label: k.label,
        circle: true,
        height: size,
        fontSize: 20,
        onKey: (d) => s.key(k, d),
      );

  Widget _rightCluster(BuildContext context) {
    return SizedBox(
      width: 140,
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [_numKey(J2meKey.num1), _numKey(J2meKey.num3)],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [_numKey(J2meKey.num7), _numKey(J2meKey.num9)],
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _openNumpad(context),
            child: Container(
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Palette.accent2.withAlpha(120)),
              ),
              child: const Text(
                'Pavé 123',
                style: TextStyle(fontWeight: FontWeight.w600, color: Palette.accent2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openNumpad(BuildContext context) {
    const rows = [
      [J2meKey.num1, J2meKey.num2, J2meKey.num3],
      [J2meKey.num4, J2meKey.num5, J2meKey.num6],
      [J2meKey.num7, J2meKey.num8, J2meKey.num9],
      [J2meKey.star, J2meKey.num0, J2meKey.pound],
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Palette.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [for (final k in row) _numKey(k, size: 72)],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
