# Don't Move — aplikasi (Flutter)

Tahap ini: onboarding, timeline tiga tab, thread, tulis, hapus, pengaturan dasar.
Chat (F2), lapor & blokir (F3), dan pemulihan akun belum ada.

- Dibangun dan dicek oleh GitHub Actions (`.github/workflows/app.yml`): `flutter analyze` + `flutter build web`.
- File platform (`web/`, `ios/`, `android/`) dibuat oleh `flutter create` di CI dan tidak di-commit.
- Uji di HP: lihat `demo/start.sh` di root repo. Aplikasi memanggil `/identity/*` dan `/api/*`
  di alamat yang sama dengan halaman web. Untuk build HP asli, isi `--dart-define=API_BASE=https://…`.
