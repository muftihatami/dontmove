package config

import (
	"reflect"
	"regexp"
	"testing"
)

// G3: Layanan Konten hanya boleh tahu satu database.
func TestExactlyOneDSNField(t *testing.T) {
	dsnLike := regexp.MustCompile(`(?i)(dsn|database|db.*url|postgres|pg.*url|vault)`)
	var hits []string
	typ := reflect.TypeOf(Config{})
	for i := 0; i < typ.NumField(); i++ {
		if dsnLike.MatchString(typ.Field(i).Name) {
			hits = append(hits, typ.Field(i).Name)
		}
	}
	if len(hits) != 1 || hits[0] != "DatabaseURL" {
		t.Fatalf("G3 dilanggar: Config Layanan Konten harus punya tepat satu field DSN (DatabaseURL), ditemukan %v", hits)
	}
}
