import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const PixelboxApp());
}

class PixelboxApp extends StatelessWidget {
  const PixelboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PixelBox',
      theme: buildTheme(),
      home: const HomeScreen(),
    );
  }
}
