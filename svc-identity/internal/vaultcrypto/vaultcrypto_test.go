package vaultcrypto

import (
	"bytes"
	"testing"
)

func keys(t *testing.T) *Keys {
	t.Helper()
	k, err := New(bytes.Repeat([]byte{1}, 32), bytes.Repeat([]byte{2}, 32))
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestLookupDeterministicAndKindSeparated(t *testing.T) {
	k := keys(t)
	a := k.Lookup(KindEmail, "a@b.co")
	if !bytes.Equal(a, k.Lookup(KindEmail, "a@b.co")) {
		t.Fatal("lookup harus deterministik")
	}
	if bytes.Equal(a, k.Lookup(KindPhone, "a@b.co")) {
		t.Fatal("kind berbeda harus menghasilkan lookup berbeda")
	}
	other, _ := New(bytes.Repeat([]byte{9}, 32), bytes.Repeat([]byte{2}, 32))
	if bytes.Equal(a, other.Lookup(KindEmail, "a@b.co")) {
		t.Fatal("pepper berbeda harus menghasilkan lookup berbeda")
	}
}

func TestSealOpenRoundTripAndAAD(t *testing.T) {
	k := keys(t)
	c, err := k.Seal(KindPhone, "+6281234567890")
	if err != nil {
		t.Fatal(err)
	}
	got, err := k.Open(KindPhone, c)
	if err != nil || got != "+6281234567890" {
		t.Fatalf("roundtrip gagal: %q %v", got, err)
	}
	if _, err := k.Open(KindEmail, c); err == nil {
		t.Fatal("ciphertext kolom phone tidak boleh bisa dibuka sebagai email")
	}
	c2, _ := k.Seal(KindPhone, "+6281234567890")
	if bytes.Equal(c, c2) {
		t.Fatal("nonce harus acak")
	}
}

func TestNormalizePhone(t *testing.T) {
	cases := map[string]string{
		"0812-3456-7890":   "+6281234567890",
		"62 812 3456 7890": "+6281234567890",
		"+6281234567890":   "+6281234567890",
	}
	for in, want := range cases {
		got, err := NormalizePhone(in)
		if err != nil || got != want {
			t.Errorf("%q → %q, %v; mau %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "12345", "abc", "+0123456789"} {
		if _, err := NormalizePhone(bad); err == nil {
			t.Errorf("%q seharusnya ditolak", bad)
		}
	}
}

func TestNormalizeEmail(t *testing.T) {
	got, err := NormalizeEmail("  Nama@Contoh.ID ")
	if err != nil || got != "nama@contoh.id" {
		t.Fatalf("got %q %v", got, err)
	}
	for _, bad := range []string{"", "bukan-email", "A <a@b.co>", "a@b.co, c@d.co"} {
		if _, err := NormalizeEmail(bad); err == nil {
			t.Errorf("%q seharusnya ditolak", bad)
		}
	}
}
