import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';

Color hexColor(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x8C939C;
  return Color(0xFF000000 | v);
}

String clock(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}.${l.minute.toString().padLeft(2, '0')}';
}

void showError(BuildContext context, Object e) {
  final msg = e is ApiError ? e.message : 'Terjadi kesalahan. Coba lagi sebentar lagi.';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

void showNote(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 4)));
}

/// Avatar dibuat dari alias: bentuk dari labelnya, warna dari kolam alias. Tidak bisa diketuk.
class AliasAvatar extends StatelessWidget {
  const AliasAvatar({super.key, required this.label, required this.color, this.size = 20});

  final String label;
  final String color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final shape = label.codeUnits.fold<int>(0, (a, b) => a + b) % 6;
    return SizedBox(
      width: size,
      height: size,
      child: ClipPath(
        clipper: _ShapeClipper(shape),
        child: ColoredBox(color: hexColor(color)),
      ),
    );
  }
}

class _ShapeClipper extends CustomClipper<Path> {
  _ShapeClipper(this.shape);

  final int shape;

  @override
  Path getClip(Size s) {
    final w = s.width, h = s.height;
    switch (shape) {
      case 0:
        return Path()..addOval(Offset.zero & s);
      case 1:
        return Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(w * 0.2)));
      case 2:
        return Path()
          ..moveTo(w / 2, h * 0.04)
          ..lineTo(w, h * 0.96)
          ..lineTo(0, h * 0.96)
          ..close();
      case 3:
        return Path()
          ..moveTo(w / 2, 0)
          ..lineTo(w, h / 2)
          ..lineTo(w / 2, h)
          ..lineTo(0, h / 2)
          ..close();
      case 4:
        return Path()
          ..moveTo(w * 0.25, h * 0.04)
          ..lineTo(w * 0.75, h * 0.04)
          ..lineTo(w, h / 2)
          ..lineTo(w * 0.75, h * 0.96)
          ..lineTo(w * 0.25, h * 0.96)
          ..lineTo(0, h / 2)
          ..close();
      default:
        return Path()
          ..addRRect(RRect.fromRectAndCorners(Offset.zero & s,
              topLeft: Radius.circular(w / 2), topRight: Radius.circular(w / 2),
              bottomLeft: Radius.circular(w * 0.15), bottomRight: Radius.circular(w * 0.15)));
    }
  }

  @override
  bool shouldReclip(_ShapeClipper old) => old.shape != shape;
}

/// Baris "avatar · alias · penanda · waktu".
class WhoRow extends StatelessWidget {
  const WhoRow({super.key, required this.alias, this.time, this.isAuthor = false, this.isMine = false});

  final Json alias;
  final String? time;
  final bool isAuthor;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      AliasAvatar(label: alias['label'] as String, color: alias['color'] as String),
      const SizedBox(width: 8),
      Flexible(
        child: Text(alias['label'] as String,
            overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      ),
      if (isAuthor) ...[const SizedBox(width: 6), const Tag('penulis')],
      if (isMine) ...[const SizedBox(width: 6), const Tag('kamu', dashed: true)],
      const Spacer(),
      if (time != null) Text(time!, style: const TextStyle(color: C.ink3, fontSize: 12)),
    ]);
  }
}

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.dashed = false});

  final String text;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: dashed ? C.ink3 : C.ink2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: dashed ? C.ink3 : C.ink2)),
    );
  }
}

/// Kotak teks sistem (garis putus-putus di wireframe).
class SysNote extends StatelessWidget {
  const SysNote(this.text, {super.key, this.warn = false, this.title});

  final String text;
  final String? title;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: warn ? C.warnBg : C.fill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(title!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: C.ink)),
          ),
        Text(text, style: const TextStyle(fontSize: 13, height: 1.45, color: C.ink2)),
      ]),
    );
  }
}

class Tombstone extends StatelessWidget {
  const Tombstone({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: C.fill, borderRadius: BorderRadius.circular(6)),
      child: const Text('Dihapus penulisnya',
          style: TextStyle(fontStyle: FontStyle.italic, color: C.ink3, fontSize: 13)),
    );
  }
}

/// Tombol yang menampilkan pemutar saat sedang bekerja.
class BusyButton extends StatelessWidget {
  const BusyButton({super.key, required this.label, required this.busy, required this.onPressed});

  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: C.paper))
          : Text(label),
    );
  }
}
