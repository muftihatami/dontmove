-- +goose Up
-- ★ SATU-SATUNYA jembatan antara dua dunia. KEPUTUSAN-F0 §6 butir 3.
CREATE TABLE shadow_link (
  shadow_id    UUID PRIMARY KEY,
  identity_id  UUID NOT NULL UNIQUE REFERENCES identity (id) ON DELETE RESTRICT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  purge_after  TIMESTAMPTZ,                     -- diisi saat akun dihapus: now() + 30 hari
  legal_hold   BOOLEAN NOT NULL DEFAULT false   -- laporan open / permintaan hukum aktif
);

CREATE INDEX shadow_link_purge_idx ON shadow_link (purge_after)
  WHERE purge_after IS NOT NULL AND NOT legal_hold;

-- +goose Down
DROP TABLE shadow_link;
