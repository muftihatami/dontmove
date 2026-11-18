import 'package:flutter/material.dart';

import 'onboarding.dart';
import 'session.dart';
import 'timeline.dart';

final navKey = GlobalKey<NavigatorState>();

void goHome() {
  navKey.currentState?.pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => const HomeShell()), (_) => false);
}

void goWelcome() {
  navKey.currentState?.pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => const WelcomeScreen()), (_) => false);
}

Future<void> signOut() async {
  await Session.setToken(null);
  goWelcome();
}
