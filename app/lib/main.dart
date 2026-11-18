import 'package:flutter/material.dart';

import 'api.dart';
import 'nav.dart';
import 'onboarding.dart';
import 'session.dart';
import 'theme.dart';
import 'timeline.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Session.init();
  Api.onUnauthorized = () {
    Session.setToken(null);
    goWelcome();
  };
  runApp(const DontMoveApp());
}

class DontMoveApp extends StatelessWidget {
  const DontMoveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navKey,
      title: "Don't Move",
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // Di layar lebar (uji di laptop) aplikasi tetap selebar HP.
      builder: (context, child) => ColoredBox(
        color: C.fill,
        child: Center(
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: child),
        ),
      ),
      home: Session.token == null ? const WelcomeScreen() : const HomeShell(),
    );
  }
}
