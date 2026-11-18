package identityclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"github.com/google/uuid"
)

// Client memanggil listener INTERNAL Layanan Identitas. Tidak ada method yang mengembalikan PII,
// karena endpoint semacam itu memang tidak ada.
type Client struct {
	BaseURL string
	Token   string // IDENTITY_INTERNAL_TOKEN
	HTTP    *http.Client
}

func New(baseURL, token string) *Client {
	return &Client{BaseURL: baseURL, Token: token, HTTP: &http.Client{Timeout: 10 * time.Second}}
}

func (c *Client) DeleteAccount(ctx context.Context, req DeleteAccountRequest) error {
	return c.do(ctx, http.MethodPost, "/internal/delete-account", req, nil)
}

func (c *Client) EnforceBan(ctx context.Context, req EnforceBanRequest) error {
	return c.do(ctx, http.MethodPost, "/internal/enforce-ban", req, nil)
}

func (c *Client) IsBanned(ctx context.Context, shadowID uuid.UUID, actor, reason string) (bool, error) {
	q := url.Values{"shadow_id": {shadowID.String()}, "actor": {actor}, "reason": {reason}}
	var out IsBannedResponse
	err := c.do(ctx, http.MethodGet, "/internal/is-banned?"+q.Encode(), nil, &out)
	return out.Banned, err
}

// StatusError membawa kode HTTP dari Layanan Identitas.
type StatusError struct {
	Status int
	Body   ErrorResponse
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("identity: %d %s", e.Status, e.Body.Code)
}

func (c *Client) do(ctx context.Context, method, path string, in, out any) error {
	var body *bytes.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	} else {
		body = bytes.NewReader(nil)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		se := &StatusError{Status: resp.StatusCode}
		_ = json.NewDecoder(resp.Body).Decode(&se.Body)
		return se
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}
