-- +goose Up
-- F1 Timeline. Satu-satunya definisi "komentar yang terlihat oleh seorang penonton".
--
-- Moderasi F3 mewajibkan penyaring yang menyembunyikan komentar dan penghitung balasan
-- per-penonton memakai fungsi yang SAMA — satu fungsi dipanggil dua kali, bukan dua implementasi.
-- Karena itu feed (jumlah balasan, tab Belum dibalas, tab Ramai) dan halaman thread
-- semuanya membaca dari fungsi ini.
--
-- Aturan F1:
--   * komentar yang dihapus penulisnya dan tidak punya balasan hidup → tidak terlihat sama sekali;
--   * komentar tingkat atas yang dihapus tapi masih punya balasan hidup → tetap ada sebagai nisan
--     (badan disembunyikan oleh API), supaya cabangnya tidak yatim.
-- F3 menambahkan penyaringan blokir (seluruh sub-pohon) DI SINI, memakai p_viewer.
-- +goose StatementBegin
CREATE FUNCTION visible_comments(p_thread UUID, p_viewer UUID)
RETURNS SETOF comment
LANGUAGE sql STABLE AS $$
  SELECT c.*
  FROM comment c
  WHERE c.thread_id = p_thread
    AND (
      c.deleted_at IS NULL
      OR (c.parent_id IS NULL AND EXISTS (
            SELECT 1 FROM comment r WHERE r.parent_id = c.id AND r.deleted_at IS NULL))
    )
$$;
-- +goose StatementEnd

-- Kuota (R4: 10 thread / 24 jam, R5: 60 komentar / 24 jam) dihitung per penulis.
CREATE INDEX thread_author_recent_idx  ON thread  (author_id, created_at DESC);
CREATE INDEX comment_author_recent_idx ON comment (author_id, created_at DESC);

-- +goose Down
DROP INDEX comment_author_recent_idx;
DROP INDEX thread_author_recent_idx;
DROP FUNCTION visible_comments(UUID, UUID);
