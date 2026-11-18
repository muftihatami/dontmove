import 'package:dontmove/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('warna alias dari hex', () {
    expect(hexColor('#3D6FE8'), const Color(0xFF3D6FE8));
    expect(hexColor('rusak'), const Color(0xFF8C939C));
  });

  testWidgets('avatar alias tergambar', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AliasAvatar(label: 'Kucing Oren', color: '#E8873D')));
    expect(find.byType(AliasAvatar), findsOneWidget);
  });
}
