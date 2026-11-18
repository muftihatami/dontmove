import 'package:flutter/material.dart';

import 'api.dart';
import 'nav.dart';
import 'theme.dart';
import 'widgets.dart';

// ---------------------------------------------------------------- ST-01 Pengaturan

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget group(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Text(t.toUpperCase(),
              style: const TextStyle(fontSize: 12, letterSpacing: 0.6, fontWeight: FontWeight.w600, color: C.ink3)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan')),
      body: ListView(children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SysNote("Kamu tidak punya profil di Don't Move. Halaman ini hanya berisi hal yang menyangkut akunmu."),
        ),
        group('Privasi'),
        ListTile(
          title: const Text('Apa yang kami simpan'),
          trailing: const Icon(Icons.chevron_right, color: C.ink3),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const StoredDataScreen())),
        ),
        const ListTile(
          enabled: false,
          title: Text('Orang yang kamu blokir'),
          subtitle: Text('Hadir bersama fitur blokir'),
        ),
        group('Akun'),
        ListTile(title: const Text('Keluar'), onTap: signOut),
        ListTile(
          title: const Text('Hapus akun', style: TextStyle(color: C.stop)),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const DeleteAccountScreen())),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Versi uji 0.1', style: TextStyle(fontSize: 12, color: C.ink3)),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- ST-02 Apa yang kami simpan

class StoredDataScreen extends StatelessWidget {
  const StoredDataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const rows = [
      ('Email', 'Untuk memulihkan akun.'),
      ('Nomor HP', 'Supaya pengganggu bisa diblokir permanen.'),
      ('Sidik perangkat', 'Supaya satu orang tidak membuat banyak akun.'),
      ('Tanggal lahir', 'Untuk memastikan usia 17 tahun ke atas.'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Apa yang kami simpan')),
      body: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        for (final (t, s) in rows) ListTile(title: Text(t), subtitle: Text(s)),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Tidak kami simpan', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Lokasimu, kontak di HP-mu, foto, dan ID iklan perangkat.', style: TextStyle(color: C.ink2)),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: SysNote('Tidak ada pengguna lain yang bisa melihat data ini. Moderator hanya melihat tulisan '
              'yang dilaporkan, tanpa email atau nomor HP.'),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- ST-04 Hapus akun

class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  bool understood = false;
  bool busy = false;

  Future<void> delete() async {
    setState(() => busy = true);
    try {
      await Api.deleteAccount();
      await signOut();
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const p = TextStyle(fontSize: 15, height: 1.5, color: C.ink2);
    return Scaffold(
      appBar: AppBar(title: const Text('Hapus akun')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Sebelum kamu menghapus akun', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          const Text.rich(TextSpan(style: p, children: [
            TextSpan(text: 'Tulisanmu tidak ikut terhapus. ', style: TextStyle(fontWeight: FontWeight.w600, color: C.ink)),
            TextSpan(
                text: 'Thread dan komentarmu tetap ada tanpa pemilik, supaya percakapan orang lain tidak berlubang. '
                    'Kalau ingin menghapusnya, hapus satu per satu dulu.'),
          ])),
          const SizedBox(height: 10),
          const Text('Email, nomor HP, dan data perangkatmu dimusnahkan dalam 30 hari. Setelah itu nomormu bisa '
              'dipakai mendaftar lagi. Kalau ada laporan atau permintaan hukum yang masih berjalan terkait akunmu, '
              'data ini kami simpan sampai urusannya selesai.', style: p),
          const SizedBox(height: 20),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: C.ink,
            value: understood,
            onChanged: (v) => setState(() => understood = v ?? false),
            title: const Text('Saya mengerti tulisan saya tidak ikut terhapus.'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.stop),
            onPressed: understood && !busy ? delete : null,
            child: Text(busy ? 'Menghapus…' : 'Hapus akun'),
          ),
        ]),
      ),
    );
  }
}
