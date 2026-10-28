import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..forward();

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder<void>(
            pageBuilder: (_, __, ___) => const HomeScreen(),
            transitionDuration: const Duration(milliseconds: 520),
            reverseTransitionDuration: Duration.zero,
            transitionsBuilder: (_, animation, __, child) => FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              ),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.985, end: 1).animate(animation),
                child: child,
              ),
            ),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Palette.bg,
        body: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final progress = Curves.easeOutCubic.transform(_controller.value);
            final rotation = _controller.value * math.pi * 0.65;
            return Stack(
              fit: StackFit.expand,
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF15223B), Palette.bg, Color(0xFF080C16)],
                    ),
                  ),
                ),
                Positioned(
                  top: -100,
                  left: -70,
                  child: _glow(280, Palette.accent.withAlpha(16)),
                ),
                Positioned(
                  bottom: -130,
                  right: -90,
                  child: _glow(340, Palette.accent2.withAlpha(18)),
                ),
                Center(
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _controller,
                      curve: const Interval(0.05, 0.65, curve: Curves.easeOut),
                    ),
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.84, end: 1).animate(
                        CurvedAnimation(
                          parent: _controller,
                          curve: const Interval(0.05, 0.65,
                              curve: Curves.easeOutBack),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 174,
                            height: 174,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Transform.rotate(
                                  angle: rotation,
                                  child: CustomPaint(
                                    size: const Size.square(170),
                                    painter: _StartupOrbitPainter(progress),
                                  ),
                                ),
                                Container(
                                  width: 112,
                                  height: 112,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(34),
                                    gradient: const LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0xFF233B5E),
                                        Color(0xFF101B2C),
                                      ],
                                    ),
                                    border: Border.all(
                                        color: Palette.accent.withAlpha(110)),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Palette.accent.withAlpha(45),
                                        blurRadius: 38,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.sports_esports_rounded,
                                    color: Palette.accent,
                                    size: 58,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          RichText(
                            text: const TextSpan(
                              style: TextStyle(
                                fontSize: 34,
                                letterSpacing: 2.2,
                              ),
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
                          const SizedBox(height: 7),
                          const Text(
                            'JAVA ME  ·  GAME SYSTEM',
                            style: TextStyle(
                              color: Palette.muted,
                              fontSize: 10,
                              letterSpacing: 2.2,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 38),
                          SizedBox(
                            width: 190,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 3,
                                backgroundColor: Palette.outline,
                                valueColor: const AlwaysStoppedAnimation(
                                    Palette.accent),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            progress < 0.85
                                ? 'PRÉPARATION DE LA CONSOLE'
                                : 'BIBLIOTHÈQUE PRÊTE',
                            style: const TextStyle(
                              color: Palette.muted,
                              fontSize: 9,
                              letterSpacing: 1.6,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 28,
                  left: 0,
                  right: 0,
                  child: Text(
                    'PIXELBOX  ·  VERSION 0.1',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Palette.muted.withAlpha(130),
                      fontSize: 9,
                      letterSpacing: 1.4,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );

  Widget _glow(double size, Color color) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color, blurRadius: size * 0.48)],
        ),
      );
}

class _StartupOrbitPainter extends CustomPainter {
  const _StartupOrbitPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: center, radius: size.width * 0.47);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Palette.accent.withAlpha(38);
    canvas.drawCircle(center, size.width * 0.43, base);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.4
      ..shader = const SweepGradient(
        colors: [Colors.transparent, Palette.accent, Palette.accent2],
      ).createShader(rect);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 1.55 * progress,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_StartupOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
