import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'nav.dart';
import 'session.dart';
import 'theme.dart';
import 'widgets.dart';

// ---------------------------------------------------------------- ON-01 Pembuka

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text("Don't Move", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const Spacer(),
            const Text('Di sini tidak ada yang tahu siapa kamu.',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600, height: 1.2, letterSpacing: -0.5)),
            const SizedBox(height: 14),
            const Text(
              'Namamu dibuat ulang di setiap obrolan. Tidak ada profil, tidak ada pengikut, '
              'tidak ada yang bisa mencarimu.',
              style: TextStyle(fontSize: 16, height: 1.5, color: C.ink2),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const RegisterFlow())),
              child: const Text('Daftar'),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LoginFlow())),
              child: const Text('Saya sudah punya akun'),
            ),
            const SizedBox(height: 14),
            const Text('Dengan mendaftar kamu menyetujui Panduan Komunitas dan Kebijakan Privasi.',
                style: TextStyle(fontSize: 12, color: C.ink3)),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- kerangka langkah

class _StepScaffold extends StatelessWidget {
  const _StepScaffold({required this.title, required this.children, this.step, this.onBack});

  final String title;
  final int? step; // 1..3
  final List<Widget> children;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: onBack ?? () => Navigator.maybePop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
          if (step != null) ...[
            Row(
              children: List.generate(
                3,
                (i) => Expanded(
                  child: Container(
                    height: 3,
                    margin: EdgeInsets.only(right: i < 2 ? 4 : 0),
                    color: i < step! ? C.ink : C.rule,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text('Langkah $step dari 3', style: const TextStyle(color: C.ink3, fontSize: 13)),
            const SizedBox(height: 18),
          ],
          ...children,
        ]),
      ),
    );
  }
}

const _h = TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.3);
const _p = TextStyle(fontSize: 15, height: 1.5, color: C.ink2);
const _small = TextStyle(fontSize: 13, color: C.ink3, height: 1.4);

Widget _codeField(TextEditingController c, void Function(String) onDone) => TextField(
      controller: c,
      autofocus: true,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
      style: const TextStyle(fontSize: 26, letterSpacing: 10, fontWeight: FontWeight.w600),
      decoration: const InputDecoration(hintText: '······'),
      onChanged: (v) {
        if (v.length == 6) onDone(v);
      },
    );

// ---------------------------------------------------------------- ON-02 … ON-07 Daftar

enum _R { email, emailCode, phone, phoneCode, birth, privacy, alreadyRegistered, notEligible }

class RegisterFlow extends StatefulWidget {
  const RegisterFlow({super.key});

  @override
  State<RegisterFlow> createState() => _RegisterFlowState();
}

class _RegisterFlowState extends State<RegisterFlow> {
  _R step = _R.email;
  bool busy = false;
  int card = 0;
  String? emailChallenge, phoneChallenge;
  final email = TextEditingController();
  final phone = TextEditingController();
  final code = TextEditingController();
  final dd = TextEditingController(), mm = TextEditingController(), yyyy = TextEditingController();

  @override
  void dispose() {
    for (final c in [email, phone, code, dd, mm, yyyy]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function() fn) async {
    setState(() => busy = true);
    try {
      await fn();
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'already_registered') {
        setState(() => step = _R.alreadyRegistered);
      } else if (e.code == 'not_eligible') {
        setState(() => step = _R.notEligible);
      } else {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void back() {
    switch (step) {
      case _R.emailCode:
        setState(() => step = _R.email);
      case _R.phone:
        setState(() => step = _R.email);
      case _R.phoneCode:
        setState(() => step = _R.phone);
      case _R.birth:
        setState(() => step = _R.phone);
      case _R.privacy:
        if (card > 0) setState(() => card--);
      default:
        Navigator.maybePop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (step) {
      case _R.email:
        return _StepScaffold(title: 'Daftar', step: 1, onBack: back, children: [
          const Text('Email kamu', style: _h),
          const SizedBox(height: 14),
          TextField(
            controller: email,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(hintText: 'nama@email.com'),
          ),
          const SizedBox(height: 10),
          const Text('Dipakai untuk memulihkan akun. Tidak pernah terlihat oleh pengguna lain.', style: _small),
          const SizedBox(height: 24),
          BusyButton(
            label: 'Kirim kode',
            busy: busy,
            onPressed: () => run(() async {
              emailChallenge = await Api.otpStart('email', email.text.trim());
              code.clear();
              setState(() => step = _R.emailCode);
            }),
          ),
        ]);

      case _R.emailCode:
        return _StepScaffold(title: 'Daftar', step: 1, onBack: back, children: [
          const Text('Cek email kamu', style: _h),
          const SizedBox(height: 8),
          Text('Kami mengirim 6 digit kode ke ${email.text.trim()}', style: _p),
          const SizedBox(height: 18),
          _codeField(code, (v) => verifyEmail(v)),
          const SizedBox(height: 18),
          BusyButton(label: 'Lanjut', busy: busy, onPressed: () => verifyEmail(code.text)),
          TextButton(onPressed: () => setState(() => step = _R.email), child: const Text('Ganti email')),
        ]);

      case _R.phone:
        return _StepScaffold(title: 'Daftar', step: 2, onBack: back, children: [
          const Text('Nomor HP kamu', style: _h),
          const SizedBox(height: 14),
          TextField(
            controller: phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: const InputDecoration(hintText: '0812 3456 7890'),
          ),
          const SizedBox(height: 14),
          const SysNote(
            'Supaya orang yang mengganggu bisa diblokir permanen dan tidak bisa kembali dengan akun baru. '
            'Nomor ini tidak pernah terlihat oleh pengguna lain, termasuk moderator.',
            title: 'Kenapa nomor HP?',
          ),
          const SizedBox(height: 24),
          BusyButton(
            label: 'Kirim kode SMS',
            busy: busy,
            onPressed: () => run(() async {
              phoneChallenge = await Api.otpStart('phone', phone.text.trim());
              code.clear();
              setState(() => step = _R.phoneCode);
            }),
          ),
        ]);

      case _R.phoneCode:
        return _StepScaffold(title: 'Daftar', step: 2, onBack: back, children: [
          const Text('Masukkan kode SMS', style: _h),
          const SizedBox(height: 8),
          Text('Dikirim ke ${phone.text.trim()}', style: _p),
          const SizedBox(height: 18),
          _codeField(code, (v) => verifyPhone(v)),
          const SizedBox(height: 18),
          BusyButton(label: 'Lanjut', busy: busy, onPressed: () => verifyPhone(code.text)),
          TextButton(onPressed: () => setState(() => step = _R.phone), child: const Text('Ganti nomor')),
        ]);

      case _R.birth:
        Widget box(TextEditingController c, String hint, int len, int flex) => Expanded(
              flex: flex,
              child: TextField(
                controller: c,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(len)],
                decoration: InputDecoration(hintText: hint),
              ),
            );
        return _StepScaffold(title: 'Daftar', step: 3, onBack: back, children: [
          const Text('Tanggal lahir', style: _h),
          const SizedBox(height: 14),
          Row(children: [
            box(dd, 'Tgl', 2, 2),
            const SizedBox(width: 8),
            box(mm, 'Bln', 2, 2),
            const SizedBox(width: 8),
            box(yyyy, 'Tahun', 4, 3),
          ]),
          const SizedBox(height: 10),
          const Text(
            "Don't Move untuk usia 17 tahun ke atas. Tanggal lahir disimpan terpisah dan tidak pernah ditampilkan.",
            style: _small,
          ),
          const SizedBox(height: 24),
          BusyButton(label: 'Lanjut', busy: busy, onPressed: submitBirth),
        ]);

      case _R.privacy:
        const cards = [
          ('Namamu berubah di setiap thread.',
              'Setiap kali kamu menulis di sebuah thread, kamu mendapat nama baru yang hanya berlaku di sana. '
                  'Di thread lain, tidak ada yang bisa mengenalimu.',
              null),
          ('Kami tahu siapa kamu.',
              'Email, nomor HP, dan perangkatmu kami simpan untuk menjaga tempat ini aman dari pengganggu.',
              'Orang lain tidak akan pernah tahu. Termasuk orang yang mengobrol denganmu.'),
          ('Tidak ada yang bisa mencari atau mengikutimu.',
              'Tidak ada profil, pengikut, atau jumlah suka. Yang diingat orang adalah apa yang kamu katakan, '
                  'bukan siapa kamu.',
              null),
        ];
        final (title, body, strong) = cards[card];
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(
                  children: List.generate(
                    3,
                    (i) => Container(
                      width: 22,
                      height: 3,
                      margin: const EdgeInsets.only(right: 4),
                      color: i <= card ? C.ink : C.rule,
                    ),
                  ),
                ),
                const Spacer(),
                Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, height: 1.2)),
                const SizedBox(height: 14),
                Text(body, style: const TextStyle(fontSize: 16, height: 1.5, color: C.ink2)),
                if (strong != null) ...[
                  const SizedBox(height: 12),
                  Text(strong, style: const TextStyle(fontSize: 16, height: 1.5, fontWeight: FontWeight.w600)),
                ],
                const Spacer(),
                Row(children: [
                  if (card > 0) ...[
                    Expanded(child: OutlinedButton(onPressed: back, child: const Text('Kembali'))),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: () => card < 2 ? setState(() => card++) : goHome(),
                      child: Text(card < 2 ? 'Lanjut' : 'Mulai'),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        );

      case _R.alreadyRegistered:
        return _StepScaffold(title: 'Daftar', onBack: () => setState(() => step = _R.phone), children: [
          const SizedBox(height: 40),
          const Text('Email atau nomor ini sudah punya akun.', style: _h),
          const SizedBox(height: 10),
          const Text('Satu email dan satu nomor hanya untuk satu akun. Kalau ini akunmu, masuk saja.', style: _p),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: () => Navigator.pushReplacement(
                context, MaterialPageRoute<void>(builder: (_) => const LoginFlow())),
            child: const Text('Masuk dengan nomor ini'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => setState(() => step = _R.email), child: const Text('Pakai data lain')),
        ]);

      case _R.notEligible:
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Spacer(),
                const Text('Kamu belum bisa mendaftar.', style: _h),
                const SizedBox(height: 10),
                const Text("Don't Move hanya untuk usia 17 tahun ke atas.", style: _p),
                const Spacer(),
                FilledButton(onPressed: goWelcome, child: const Text('Tutup')),
              ]),
            ),
          ),
        );
    }
  }

  void verifyEmail(String v) => run(() async {
        await Api.otpVerify(emailChallenge!, v);
        setState(() => step = _R.phone);
      });

  void verifyPhone(String v) => run(() async {
        await Api.otpVerify(phoneChallenge!, v);
        setState(() => step = _R.birth);
      });

  void submitBirth() {
    final d = int.tryParse(dd.text), m = int.tryParse(mm.text), y = int.tryParse(yyyy.text);
    final valid = d != null && m != null && y != null && y > 1900 && m >= 1 && m <= 12 && d >= 1 && d <= 31;
    final date = valid ? DateTime(y, m, d) : null;
    if (date == null || date.day != d || date.month != m) {
      showNote(context, 'Tanggal lahir tidak valid.');
      return;
    }
    final iso = '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
    run(() async {
      final token = await Api.register(
        emailChallenge: emailChallenge!,
        email: email.text.trim(),
        phoneChallenge: phoneChallenge!,
        phone: phone.text.trim(),
        birthDate: iso,
      );
      await Session.setToken(token);
      setState(() {
        card = 0;
        step = _R.privacy;
      });
    });
  }
}

// ---------------------------------------------------------------- ON-08 Masuk

class LoginFlow extends StatefulWidget {
  const LoginFlow({super.key});

  @override
  State<LoginFlow> createState() => _LoginFlowState();
}

class _LoginFlowState extends State<LoginFlow> {
  final phone = TextEditingController();
  final code = TextEditingController();
  String? challenge;
  bool busy = false;

  @override
  void dispose() {
    phone.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() fn) async {
    setState(() => busy = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void verify(String v) => run(() async {
        await Api.otpVerify(challenge!, v);
        final token = await Api.login(phoneChallenge: challenge!, phone: phone.text.trim());
        await Session.setToken(token);
        goHome();
      });

  @override
  Widget build(BuildContext context) {
    if (challenge == null) {
      return _StepScaffold(title: 'Masuk', children: [
        const Text('Nomor HP yang kamu daftarkan', style: _h),
        const SizedBox(height: 14),
        TextField(
          controller: phone,
          autofocus: true,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(hintText: '0812 3456 7890'),
        ),
        const SizedBox(height: 24),
        BusyButton(
          label: 'Kirim kode SMS',
          busy: busy,
          onPressed: () => run(() async {
            final id = await Api.otpStart('phone', phone.text.trim());
            setState(() => challenge = id);
          }),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => showNote(context, 'Pemulihan akun lewat email belum tersedia di versi uji ini.'),
          child: const Text('Nomor sudah tidak aktif?'),
        ),
      ]);
    }
    return _StepScaffold(title: 'Masuk', onBack: () => setState(() => challenge = null), children: [
      const Text('Masukkan kode SMS', style: _h),
      const SizedBox(height: 8),
      Text('Dikirim ke ${phone.text.trim()}', style: _p),
      const SizedBox(height: 18),
      _codeField(code, verify),
      const SizedBox(height: 18),
      BusyButton(label: 'Masuk', busy: busy, onPressed: () => verify(code.text)),
    ]);
  }
}
