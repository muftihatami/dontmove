package api

// F1 Timeline: thread, komentar, feed tiga tab (K9), alias per-thread, kuota, hapus tulisan sendiri.
//
// Aturan yang dijaga di file ini:
//   - shadow_id dan author_id tidak pernah dikirim ke klien; yang keluar hanya alias + is_mine.
//   - Waktu hanya dalam label kasar (relTime), tidak pernah cap waktu presisi.
//   - Jumlah balasan dan penyaringan feed memakai visible_comments() per penonton (lihat migrasi 00007).
//   - Alias lahir dari MENULIS (thread atau komentar), tidak pernah dari membaca (T7).

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/dontmove/svc-content/internal/auth"
	"github.com/dontmove/svc-content/internal/contentdb"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const (
	maxBody        = 1000
	threadQuota    = 10 // per 24 jam (R4)
	commentQuota   = 60 // per 24 jam (R5)
	defaultPage    = 20
	maxPage        = 50
	tombstoneLabel = "Dihapus penulisnya"
)

var errThreadFull = errors.New("kolam alias habis untuk thread ini")

type aliasDTO struct {
	Label string `json:"label"`
	Color string `json:"color"`
}

type threadDTO struct {
	ID         uuid.UUID `json:"id"`
	Alias      aliasDTO  `json:"alias"`
	IsMine     bool      `json:"is_mine"`
	Body       *string   `json:"body"` // null = nisan
	Deleted    bool      `json:"deleted"`
	Time       string    `json:"time"`
	ReplyCount int32     `json:"reply_count"`
}

type commentDTO struct {
	ID       uuid.UUID  `json:"id"`
	ParentID *uuid.UUID `json:"parent_id"`
	Alias    aliasDTO   `json:"alias"`
	IsAuthor bool       `json:"is_author"` // penanda "penulis", hanya berlaku di thread ini
	IsMine   bool       `json:"is_mine"`
	Body     *string    `json:"body"` // null = nisan
	Deleted  bool       `json:"deleted"`
	Time     string     `json:"time"`
}

type quotaErr struct {
	Code    string    `json:"code"`
	Message string    `json:"message"`
	RetryAt time.Time `json:"retry_at"` // milik pengguna sendiri, dibulatkan ke menit
}

// ---------- feed ----------

func (s *Server) feed(w http.ResponseWriter, r *http.Request) {
	viewer := auth.ShadowID(r.Context())
	q := contentdb.New(s.Pool)
	lim := pageSize(r)
	now := time.Now()
	tab := r.URL.Query().Get("tab")
	if tab == "" {
		tab = "terbaru"
	}
	items := []threadDTO{}
	next := ""

	switch tab {
	case "terbaru":
		var cursor uuid.NullUUID
		if c := r.URL.Query().Get("cursor"); c != "" {
			id, err := uuid.Parse(c)
			if err != nil {
				writeErr(w, http.StatusBadRequest, "invalid_cursor", "Halaman tidak valid.")
				return
			}
			cursor = uuid.NullUUID{UUID: id, Valid: true}
		}
		rows, err := q.FeedLatest(r.Context(), contentdb.FeedLatestParams{Viewer: viewer, Cursor: cursor, Lim: lim})
		if err != nil {
			s.internal(w, err)
			return
		}
		for _, t := range rows {
			items = append(items, feedItem(t.ID, t.AuthorID, t.Body, t.Label, t.ColorHex, t.CreatedAt, t.ReplyCount, viewer, now))
		}
		if len(rows) == int(lim) {
			next = rows[len(rows)-1].ID.String()
		}
	case "belum-dibalas", "ramai":
		page, err := pageNumber(r)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "invalid_cursor", "Halaman tidak valid.")
			return
		}
		off := page * lim
		if tab == "belum-dibalas" {
			rows, err := q.FeedUnanswered(r.Context(), contentdb.FeedUnansweredParams{Viewer: viewer, Lim: lim, Off: off})
			if err != nil {
				s.internal(w, err)
				return
			}
			for _, t := range rows {
				items = append(items, feedItem(t.ID, t.AuthorID, t.Body, t.Label, t.ColorHex, t.CreatedAt, 0, viewer, now))
			}
		} else {
			rows, err := q.FeedBusy(r.Context(), contentdb.FeedBusyParams{Viewer: viewer, Lim: lim, Off: off})
			if err != nil {
				s.internal(w, err)
				return
			}
			for _, t := range rows {
				items = append(items, feedItem(t.ID, t.AuthorID, t.Body, t.Label, t.ColorHex, t.CreatedAt, t.ReplyCount, viewer, now))
			}
		}
		if len(items) == int(lim) {
			next = strconv.Itoa(int(page) + 1)
		}
	default:
		writeErr(w, http.StatusBadRequest, "invalid_tab", "Tab tidak dikenal.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"tab": tab, "items": items, "next": next})
}

func feedItem(id, author uuid.UUID, body, label, color string, created time.Time, replies int32, viewer uuid.UUID, now time.Time) threadDTO {
	b := body
	return threadDTO{ID: id, Alias: aliasDTO{label, color}, IsMine: author == viewer, Body: &b,
		Time: relTime(created, now), ReplyCount: replies}
}

// ---------- thread ----------

func (s *Server) createThread(w http.ResponseWriter, r *http.Request) {
	me := auth.ShadowID(r.Context())
	body, ok := readBody(w, r)
	if !ok {
		return
	}
	var out threadDTO
	var remaining int32
	err := s.inTx(r.Context(), func(q *contentdb.Queries, tx pgx.Tx) error {
		if err := q.LockAccount(r.Context(), me); err != nil {
			return err
		}
		used, err := q.ThreadQuota(r.Context(), me)
		if err != nil {
			return err
		}
		if used.Used >= threadQuota {
			return quotaError{retryAt: used.Oldest.Add(24 * time.Hour)}
		}
		t, err := q.CreateThread(r.Context(), contentdb.CreateThreadParams{AuthorID: me, Body: body})
		if err != nil {
			return err
		}
		alias, _, err := ensureAlias(r.Context(), tx, t.ID, me)
		if err != nil {
			return err
		}
		out = threadDTO{ID: t.ID, Alias: alias, IsMine: true, Body: &body, Time: relTime(t.CreatedAt, time.Now())}
		remaining = threadQuota - used.Used - 1
		return nil
	})
	if s.txErr(w, err) {
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"thread": out, "threads_remaining": remaining})
}

func (s *Server) getThread(w http.ResponseWriter, r *http.Request) {
	viewer := auth.ShadowID(r.Context())
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	q := contentdb.New(s.Pool)
	t, err := q.GetThread(r.Context(), id)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, "not_found", "Thread tidak ditemukan.")
		return
	} else if err != nil {
		s.internal(w, err)
		return
	}
	rows, err := q.ListThreadComments(r.Context(), contentdb.ListThreadCommentsParams{ThreadID: id, Viewer: viewer})
	if err != nil {
		s.internal(w, err)
		return
	}
	deleted := t.DeletedAt != nil
	// Thread yang dihapus tanpa balasan yang terlihat hilang sepenuhnya.
	if deleted && len(rows) == 0 {
		writeErr(w, http.StatusNotFound, "not_found", "Thread tidak ditemukan.")
		return
	}
	now := time.Now()
	var live int32
	comments := make([]commentDTO, 0, len(rows))
	for _, c := range rows {
		dto := commentDTO{ID: c.ID, Alias: aliasDTO{c.Label, c.ColorHex}, IsAuthor: c.AuthorID == t.AuthorID,
			IsMine: c.AuthorID == viewer, Time: relTime(c.CreatedAt, now)}
		if c.ParentID.Valid {
			p := c.ParentID.UUID
			dto.ParentID = &p
		}
		if c.DeletedAt != nil {
			dto.Deleted = true // nisan: badan tidak dikirim
		} else {
			b := c.Body
			dto.Body = &b
			live++
		}
		comments = append(comments, dto)
	}
	th := threadDTO{ID: t.ID, Alias: aliasDTO{t.Label, t.ColorHex}, IsMine: t.AuthorID == viewer,
		Deleted: deleted, Time: relTime(t.CreatedAt, now), ReplyCount: live}
	if !deleted {
		b := t.Body
		th.Body = &b
	}
	var my *aliasDTO
	if a, err := q.GetMyAlias(r.Context(), contentdb.GetMyAliasParams{ThreadID: id, ShadowID: viewer}); err == nil {
		my = &aliasDTO{a.Label, a.ColorHex}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"thread": th, "comments": comments,
		"my_alias": my,     // null = belum pernah menulis di sini ("Kamu belum punya nama di thread ini")
		"closed":   deleted, // thread dihapus penulisnya: terbaca, tapi tidak menerima balasan baru
	})
}

func (s *Server) deleteThread(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	n, err := contentdb.New(s.Pool).SoftDeleteThread(r.Context(),
		contentdb.SoftDeleteThreadParams{ID: id, AuthorID: auth.ShadowID(r.Context())})
	if err != nil {
		s.internal(w, err)
		return
	}
	if n == 0 { // tidak ada, bukan milikmu, atau sudah dihapus: jawabannya sama
		writeErr(w, http.StatusNotFound, "not_found", "Thread tidak ditemukan.")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- komentar ----------

type commentReq struct {
	Body     string     `json:"body"`
	ParentID *uuid.UUID `json:"parent_id"`
}

func (s *Server) createComment(w http.ResponseWriter, r *http.Request) {
	me := auth.ShadowID(r.Context())
	threadID, ok := pathID(w, r)
	if !ok {
		return
	}
	var req commentReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_body", "Permintaan tidak valid.")
		return
	}
	body, ok := cleanBody(w, req.Body)
	if !ok {
		return
	}
	var out commentDTO
	var aliasNew bool
	err := s.inTx(r.Context(), func(q *contentdb.Queries, tx pgx.Tx) error {
		if err := q.LockAccount(r.Context(), me); err != nil {
			return err
		}
		t, err := q.GetThreadState(r.Context(), threadID)
		if errors.Is(err, pgx.ErrNoRows) {
			return apiError{http.StatusNotFound, "not_found", "Thread tidak ditemukan."}
		} else if err != nil {
			return err
		}
		if t.DeletedAt != nil {
			return apiError{http.StatusGone, "thread_closed", "Penulis menghapus thread ini. Thread ini tidak menerima balasan baru."}
		}
		var parent uuid.NullUUID
		if req.ParentID != nil {
			p, err := q.GetCommentState(r.Context(), *req.ParentID)
			if errors.Is(err, pgx.ErrNoRows) || (err == nil && p.ThreadID != threadID) {
				return apiError{http.StatusNotFound, "not_found", "Komentar yang dibalas tidak ditemukan."}
			} else if err != nil {
				return err
			}
			vis, err := q.IsCommentVisible(r.Context(), contentdb.IsCommentVisibleParams{ThreadID: threadID, Viewer: me, CommentID: p.ID})
			if err != nil {
				return err
			}
			if !vis {
				return apiError{http.StatusNotFound, "not_found", "Komentar yang dibalas tidak ditemukan."}
			}
			// K3: balasan maksimal satu tingkat. Membalas sebuah balasan → induknya komentar tingkat atas.
			root := p.ID
			if p.ParentID.Valid {
				root = p.ParentID.UUID
			}
			parent = uuid.NullUUID{UUID: root, Valid: true}
		}
		used, err := q.CommentQuota(r.Context(), me)
		if err != nil {
			return err
		}
		if used.Used >= commentQuota {
			return quotaError{retryAt: used.Oldest.Add(24 * time.Hour)}
		}
		alias, isNew, err := ensureAlias(r.Context(), tx, threadID, me)
		if err != nil {
			return err
		}
		c, err := q.CreateComment(r.Context(), contentdb.CreateCommentParams{ThreadID: threadID, ParentID: parent, AuthorID: me, Body: body})
		if err != nil {
			return err
		}
		if err := q.TouchThread(r.Context(), threadID); err != nil {
			return err
		}
		out = commentDTO{ID: c.ID, Alias: alias, IsAuthor: me == t.AuthorID, IsMine: true, Body: &body, Time: relTime(c.CreatedAt, time.Now())}
		if parent.Valid {
			p := parent.UUID
			out.ParentID = &p
		}
		aliasNew = isNew
		return nil
	})
	if s.txErr(w, err) {
		return
	}
	// alias_new = true → klien menampilkan toast "Di thread ini kamu <alias>" (TH-02), sekali per thread.
	writeJSON(w, http.StatusCreated, map[string]any{"comment": out, "alias_new": aliasNew})
}

func (s *Server) deleteComment(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	n, err := contentdb.New(s.Pool).SoftDeleteComment(r.Context(),
		contentdb.SoftDeleteCommentParams{ID: id, AuthorID: auth.ShadowID(r.Context())})
	if err != nil {
		s.internal(w, err)
		return
	}
	if n == 0 {
		writeErr(w, http.StatusNotFound, "not_found", "Komentar tidak ditemukan.")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- kuota ----------

func (s *Server) quota(w http.ResponseWriter, r *http.Request) {
	me := auth.ShadowID(r.Context())
	q := contentdb.New(s.Pool)
	t, err := q.ThreadQuota(r.Context(), me)
	if err != nil {
		s.internal(w, err)
		return
	}
	c, err := q.CommentQuota(r.Context(), me)
	if err != nil {
		s.internal(w, err)
		return
	}
	// K5: aplikasi hanya menampilkan sisa thread saat tinggal ≤ 3.
	writeJSON(w, http.StatusOK, map[string]int32{
		"threads_remaining":  max(0, threadQuota-t.Used),
		"comments_remaining": max(0, commentQuota-c.Used),
	})
}

// ---------- alias ----------

// ensureAlias memberi alias kepada (thread, me) kalau belum ada. Alias diambil acak dari kolam (A4).
// Dua penulis baru yang kebetulan mendapat alias sama ditolak UNIQUE (thread_id, alias_id);
// percobaan diulang di dalam savepoint.
func ensureAlias(ctx context.Context, tx pgx.Tx, threadID, me uuid.UUID) (aliasDTO, bool, error) {
	for attempt := 0; attempt < 5; attempt++ {
		sp, err := tx.Begin(ctx)
		if err != nil {
			return aliasDTO{}, false, err
		}
		_, err = contentdb.New(sp).AssignAlias(ctx, contentdb.AssignAliasParams{ThreadID: threadID, ShadowID: me})
		var pgErr *pgconn.PgError
		switch {
		case err == nil:
			if err := sp.Commit(ctx); err != nil {
				return aliasDTO{}, false, err
			}
			a, err := contentdb.New(tx).GetMyAlias(ctx, contentdb.GetMyAliasParams{ThreadID: threadID, ShadowID: me})
			return aliasDTO{a.Label, a.ColorHex}, true, err
		case errors.Is(err, pgx.ErrNoRows):
			_ = sp.Rollback(ctx)
			a, err := contentdb.New(tx).GetMyAlias(ctx, contentdb.GetMyAliasParams{ThreadID: threadID, ShadowID: me})
			if errors.Is(err, pgx.ErrNoRows) {
				return aliasDTO{}, false, errThreadFull
			}
			return aliasDTO{a.Label, a.ColorHex}, false, err
		case errors.As(err, &pgErr) && pgErr.Code == "23505":
			_ = sp.Rollback(ctx) // tabrakan alias dengan penulis lain; coba lagi
		default:
			_ = sp.Rollback(ctx)
			return aliasDTO{}, false, err
		}
	}
	return aliasDTO{}, false, errors.New("gagal memberi alias setelah 5 percobaan")
}

// ---------- pembantu ----------

type apiError struct {
	status        int
	code, message string
}

func (e apiError) Error() string { return e.code }

type quotaError struct{ retryAt time.Time }

func (e quotaError) Error() string { return "quota_exceeded" }

func (s *Server) inTx(ctx context.Context, fn func(q *contentdb.Queries, tx pgx.Tx) error) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if err := fn(contentdb.New(tx), tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// txErr menulis respons untuk error dari inTx. true = respons sudah ditulis.
func (s *Server) txErr(w http.ResponseWriter, err error) bool {
	if err == nil {
		return false
	}
	var ae apiError
	var qe quotaError
	switch {
	case errors.As(err, &ae):
		writeErr(w, ae.status, ae.code, ae.message)
	case errors.As(err, &qe):
		writeJSON(w, http.StatusTooManyRequests, quotaErr{Code: "quota_exceeded",
			Message: "Kamu sudah mencapai batas untuk 24 jam terakhir.", RetryAt: qe.retryAt.UTC().Truncate(time.Minute)})
	case errors.Is(err, errThreadFull):
		writeErr(w, http.StatusConflict, "thread_full", "Thread ini sudah terlalu ramai untuk peserta baru.")
	default:
		s.internal(w, err)
	}
	return true
}

func readBody(w http.ResponseWriter, r *http.Request) (string, bool) {
	var req struct {
		Body string `json:"body"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_body", "Permintaan tidak valid.")
		return "", false
	}
	return cleanBody(w, req.Body)
}

func cleanBody(w http.ResponseWriter, raw string) (string, bool) {
	b := strings.TrimSpace(raw)
	if n := utf8.RuneCountInString(b); n == 0 || n > maxBody {
		writeErr(w, http.StatusBadRequest, "invalid_body", "Tulisan harus 1 sampai 1.000 karakter.")
		return "", false
	}
	return b, true
}

func pathID(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "Tidak ditemukan.")
		return uuid.Nil, false
	}
	return id, true
}

func pageSize(r *http.Request) int32 {
	n, err := strconv.Atoi(r.URL.Query().Get("limit"))
	if err != nil || n <= 0 {
		return defaultPage
	}
	return int32(min(n, maxPage))
}

func pageNumber(r *http.Request) (int32, error) {
	c := r.URL.Query().Get("cursor")
	if c == "" {
		return 0, nil
	}
	n, err := strconv.Atoi(c)
	if err != nil || n < 0 || n > 1000 {
		return 0, errors.New("cursor")
	}
	return int32(n), nil
}
