package api

import (
	"fmt"
	"time"
)

// relTime mengubah waktu menjadi label kasar ("2 mnt", "kemarin").
// Cap waktu presisi tidak pernah dikirim ke klien: pola waktu adalah kebocoran korelasi
// yang tersisa setelah alias (arsitektur §5.4).
func relTime(t, now time.Time) string {
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "baru saja"
	case d < time.Hour:
		return fmt.Sprintf("%d mnt", int(d/time.Minute))
	case d < 24*time.Hour:
		return fmt.Sprintf("%d jam", int(d/time.Hour))
	case d < 48*time.Hour:
		return "kemarin"
	case d < 7*24*time.Hour:
		return fmt.Sprintf("%d hari", int(d/(24*time.Hour)))
	case d < 35*24*time.Hour:
		return fmt.Sprintf("%d mgg", int(d/(7*24*time.Hour)))
	case d < 365*24*time.Hour:
		return fmt.Sprintf("%d bln", int(d/(30*24*time.Hour)))
	default:
		return "lebih dari setahun"
	}
}
