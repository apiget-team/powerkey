package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---------------- 测试脚手架 ----------------

// newTestApp 构造一个指向给定 admin handler 的 app（store 落到临时目录，避免污染工作区）。
func newTestApp(t *testing.T, adminBase string) *app {
	t.Helper()
	return &app{
		cfg: &config{
			adminBase:      adminBase,
			umbrellaToken:  "umbrella-access-token",
			umbrellaUser:   "31",
			publicBase:     "https://api.apiget.cc",
			model:          "deepseek-v4-pro",
			group:          "",
			quotaUSD:       2,
			fallbackURL:    "https://apiget.cc/register?ref=powerkey",
			ratePerIPDay:   20,
			trustXFFDepth:  1,
			minUmbrellaUSD: 4,
			storePath:      filepath.Join(t.TempDir(), "issued.json"),
		},
		http:  &http.Client{Timeout: 5 * time.Second},
		store: newStore(filepath.Join(t.TempDir(), "issued.json")),
		ipl:   newIPLimiter(),
	}
}

// appWithBody 返回一个 admin 永远回固定 status+body 的 app —— 用于 parse 类单测。
func appWithBody(t *testing.T, status int, body string) (*app, func()) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	return newTestApp(t, srv.URL), srv.Close
}

// mockNewAPI 模拟 new-api 用户级 token API（create→search→key）+ /api/user/self 余额。
type mockNewAPI struct {
	srv         *httptest.Server
	mu          sync.Mutex
	quota       float64 // /api/user/self 的 data.quota（quota 单位）
	selfStatus  int     // 0 => 200；非 0 用于模拟余额检查失败（fail-open 路径）
	selfCalls   int
	createCalls int
	keyCalls    int
	nextID      int
	nameByID    map[int]string
	gotAuth     string // 最近一次请求带的 Authorization 头（验证双头契约）
	gotUser     string
}

func newMockNewAPI() *mockNewAPI {
	m := &mockNewAPI{quota: 100 * quotaPerUnit, nextID: 1000, nameByID: map[int]string{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/user/self", m.handleSelf)
	mux.HandleFunc("/api/token/search", m.handleSearch)
	mux.HandleFunc("/api/token/", m.handleToken) // 子树：POST 创建 + POST /:id/key 取 key
	m.srv = httptest.NewServer(mux)
	return m
}

func (m *mockNewAPI) close() { m.srv.Close() }

func (m *mockNewAPI) record(r *http.Request) {
	m.gotAuth = r.Header.Get("Authorization")
	m.gotUser = r.Header.Get("New-Api-User")
}

func (m *mockNewAPI) handleSelf(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.selfCalls++
	m.record(r)
	if m.selfStatus != 0 {
		w.WriteHeader(m.selfStatus)
		_, _ = io.WriteString(w, `{"success":false,"message":"boom"}`)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success": true, "message": "",
		"data": map[string]any{"id": 31, "username": "powerkey-trial", "quota": m.quota, "used_quota": 0},
	})
}

func (m *mockNewAPI) handleToken(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.record(r)
	if strings.HasSuffix(r.URL.Path, "/key") {
		m.keyCalls++
		idStr := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/token/"), "/key")
		id, _ := strconv.Atoi(idStr)
		writeJSON(w, http.StatusOK, map[string]any{
			"success": true, "message": "", "data": map[string]any{"key": "sk-key-" + strconv.Itoa(id)},
		})
		return
	}
	// 创建：读 name，分配 id，记录以供 search 回放。
	var body map[string]any
	b, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
	_ = json.Unmarshal(b, &body)
	name, _ := body["name"].(string)
	m.createCalls++
	id := m.nextID
	m.nextID++
	m.nameByID[id] = name
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": ""})
}

func (m *mockNewAPI) handleSearch(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.record(r)
	keyword := r.URL.Query().Get("keyword")
	items := []any{}
	for id, name := range m.nameByID {
		if name == keyword {
			items = append(items, map[string]any{"id": id, "name": name})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success": true, "message": "",
		"data": map[string]any{"page": 1, "page_size": 10, "total": len(items), "items": items},
	})
}

func doIssue(t *testing.T, a *app, xff string, req map[string]any) issueResp {
	t.Helper()
	var rdr io.Reader
	if req != nil {
		b, _ := json.Marshal(req)
		rdr = strings.NewReader(string(b))
	}
	r := httptest.NewRequest(http.MethodPost, "/issue", rdr)
	r.RemoteAddr = "10.0.0.1:5555"
	if xff != "" {
		r.Header.Set("X-Forwarded-For", xff)
	}
	rec := httptest.NewRecorder()
	a.handleIssue(rec, r)
	var resp issueResp
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode issue resp: %v (body=%s)", err, rec.Body.String())
	}
	return resp
}

// ---------------- parse 类表测试（对照已核实的 new-api 返回体形状） ----------------

func TestDataMap(t *testing.T) {
	cases := []struct {
		name string
		in   map[string]any
		want bool // 是否取到非 nil data
	}{
		{"wrapped object", map[string]any{"success": true, "data": map[string]any{"key": "x"}}, true},
		{"no data", map[string]any{"success": true, "message": ""}, false},
		{"data is array", map[string]any{"data": []any{map[string]any{"id": 1.0}}}, false},
		{"data is string", map[string]any{"data": "nope"}, false},
		{"nil map", nil, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := dataMap(c.in) != nil
			if got != c.want {
				t.Fatalf("dataMap non-nil = %v, want %v", got, c.want)
			}
		})
	}
}

func TestFindTokenID(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		search  string
		wantID  int
		wantErr bool
	}{
		{
			name:   "pageInfo items shape",
			body:   `{"success":true,"message":"","data":{"page":1,"page_size":10,"total":1,"items":[{"id":1000,"name":"powerkey-abc"}]}}`,
			search: "powerkey-abc", wantID: 1000,
		},
		{
			name:   "data as array fallback",
			body:   `{"success":true,"data":[{"id":2000,"name":"powerkey-xyz"}]}`,
			search: "powerkey-xyz", wantID: 2000,
		},
		{
			name:   "name mismatch -> not found",
			body:   `{"success":true,"data":{"items":[{"id":1,"name":"other"}]}}`,
			search: "powerkey-abc", wantErr: true,
		},
		{
			name:   "empty items -> not found",
			body:   `{"success":true,"data":{"items":[]}}`,
			search: "powerkey-abc", wantErr: true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a, closeFn := appWithBody(t, http.StatusOK, c.body)
			defer closeFn()
			id, err := a.findTokenID(c.search)
			if c.wantErr {
				if err == nil {
					t.Fatalf("want err, got id=%d", id)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
			if id != c.wantID {
				t.Fatalf("id = %d, want %d", id, c.wantID)
			}
		})
	}
}

func TestFetchKey(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		want    string
		wantErr bool
	}{
		{"data.key shape", `{"success":true,"message":"","data":{"key":"sk-abc123"}}`, "sk-abc123", false},
		{"top-level key fallback", `{"key":"sk-top"}`, "sk-top", false},
		{"missing key", `{"success":true,"data":{}}`, "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a, closeFn := appWithBody(t, http.StatusOK, c.body)
			defer closeFn()
			k, err := a.fetchKey(42)
			if c.wantErr {
				if err == nil {
					t.Fatalf("want err, got key=%q", k)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
			if k != c.want {
				t.Fatalf("key = %q, want %q", k, c.want)
			}
		})
	}
}

func TestUmbrellaRemainingUSD(t *testing.T) {
	cases := []struct {
		name      string
		status    int
		body      string
		wantUSD   float64
		wantKnown bool
	}{
		{"healthy 2 USD", http.StatusOK, `{"success":true,"message":"","data":{"quota":1000000,"used_quota":0}}`, 2, true},
		{"healthy 50 USD", http.StatusOK, `{"success":true,"data":{"quota":25000000}}`, 50, true},
		{"missing quota", http.StatusOK, `{"success":true,"data":{"used_quota":1}}`, 0, false},
		{"quota not number", http.StatusOK, `{"success":true,"data":{"quota":"oops"}}`, 0, false},
		{"no data", http.StatusOK, `{"success":true,"message":""}`, 0, false},
		{"http 500", http.StatusInternalServerError, `{"success":false,"message":"boom"}`, 0, false},
		{"success false", http.StatusOK, `{"success":false,"message":"unauthorized"}`, 0, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a, closeFn := appWithBody(t, c.status, c.body)
			defer closeFn()
			usd, known, err := a.umbrellaRemainingUSD()
			if known != c.wantKnown {
				t.Fatalf("known = %v, want %v (err=%v)", known, c.wantKnown, err)
			}
			if !c.wantKnown {
				if err == nil {
					t.Fatalf("want err when not known")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
			if usd != c.wantUSD {
				t.Fatalf("usd = %v, want %v", usd, c.wantUSD)
			}
		})
	}
}

func TestClientIP(t *testing.T) {
	cases := []struct {
		name       string
		xff        string
		depth      int
		remoteAddr string
		want       string
	}{
		{"single hop depth1", "1.2.3.4", 1, "10.0.0.1:9", "1.2.3.4"},
		{"spoofed first, trust last", "9.9.9.9, 1.2.3.4", 1, "10.0.0.1:9", "1.2.3.4"},
		{"three hops depth1 -> last", "fake, mid, edge", 1, "10.0.0.1:9", "edge"},
		{"three hops depth2 -> second last", "fake, mid, edge", 2, "10.0.0.1:9", "mid"},
		{"no xff -> remoteaddr", "", 1, "5.6.7.8:1234", "5.6.7.8"},
		{"depth0 ignores xff", "1.2.3.4", 0, "5.6.7.8:1234", "5.6.7.8"},
		{"depth exceeds hops -> remoteaddr", "1.2.3.4", 5, "5.6.7.8:1234", "5.6.7.8"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "/issue", nil)
			r.RemoteAddr = c.remoteAddr
			if c.xff != "" {
				r.Header.Set("X-Forwarded-For", c.xff)
			}
			if got := clientIP(r, c.depth); got != c.want {
				t.Fatalf("clientIP = %q, want %q", got, c.want)
			}
		})
	}
}

// ---------------- handleIssue 行为测试（httptest mock new-api） ----------------

func TestHandleIssue_FingerprintDedup(t *testing.T) {
	m := newMockNewAPI()
	defer m.close()
	a := newTestApp(t, m.srv.URL)
	// 预置 store：同指纹已发过 id=777 → 复用、按 id 重新取 key，不重铸、不查余额。
	a.store.put("fp-dedup", issuedRec{ID: 777, Model: "deepseek-v4-pro", QuotaUSD: 2})

	resp := doIssue(t, a, "1.1.1.1", map[string]any{"fingerprint": "fp-dedup"})
	if !resp.OK || resp.Token != "sk-key-777" {
		t.Fatalf("dedup reuse failed: %+v", resp)
	}
	if m.createCalls != 0 {
		t.Fatalf("dedup should not mint, createCalls=%d", m.createCalls)
	}
	if m.selfCalls != 0 {
		t.Fatalf("dedup should short-circuit before balance check, selfCalls=%d", m.selfCalls)
	}
}

func TestHandleIssue_PerIPCap(t *testing.T) {
	m := newMockNewAPI()
	defer m.close()
	a := newTestApp(t, m.srv.URL)
	a.cfg.ratePerIPDay = 1

	r1 := doIssue(t, a, "9.9.9.9", map[string]any{"fingerprint": "fp-A"})
	if !r1.OK {
		t.Fatalf("first request should mint: %+v", r1)
	}
	r2 := doIssue(t, a, "9.9.9.9", map[string]any{"fingerprint": "fp-B"})
	if r2.OK || r2.Reason != "rate_limited" {
		t.Fatalf("second request should be rate_limited: %+v", r2)
	}
	if r2.FallbackURL != a.cfg.fallbackURL {
		t.Fatalf("rate_limited should carry fallback url, got %q", r2.FallbackURL)
	}
	if m.createCalls != 1 {
		t.Fatalf("only one mint expected, createCalls=%d", m.createCalls)
	}
}

func TestHandleIssue_BalanceGuardFallback(t *testing.T) {
	m := newMockNewAPI()
	defer m.close()
	m.quota = 1 * quotaPerUnit // $1 remaining < minUmbrellaUSD ($4)
	a := newTestApp(t, m.srv.URL)

	resp := doIssue(t, a, "2.2.2.2", map[string]any{"fingerprint": "fp-low"})
	if resp.OK || resp.Reason != "umbrella_exhausted" {
		t.Fatalf("low balance should serve fallback: %+v", resp)
	}
	if resp.FallbackURL != a.cfg.fallbackURL {
		t.Fatalf("umbrella_exhausted should carry fallback url, got %q", resp.FallbackURL)
	}
	if m.createCalls != 0 {
		t.Fatalf("must NOT mint when umbrella exhausted, createCalls=%d", m.createCalls)
	}
	if m.selfCalls != 1 {
		t.Fatalf("balance must be checked once, selfCalls=%d", m.selfCalls)
	}
}

func TestHandleIssue_BalanceGuardBoundary(t *testing.T) {
	m := newMockNewAPI()
	defer m.close()
	m.quota = 4 * quotaPerUnit // exactly == threshold ($4); guard uses strict < so this mints
	a := newTestApp(t, m.srv.URL)

	resp := doIssue(t, a, "2.2.2.3", map[string]any{"fingerprint": "fp-boundary"})
	if !resp.OK {
		t.Fatalf("remaining == threshold should still mint (strict <): %+v", resp)
	}
	if m.createCalls != 1 {
		t.Fatalf("expected mint at boundary, createCalls=%d", m.createCalls)
	}
}

func TestHandleIssue_BalanceGuardFailOpen(t *testing.T) {
	m := newMockNewAPI()
	defer m.close()
	m.selfStatus = http.StatusInternalServerError // balance check errors
	a := newTestApp(t, m.srv.URL)

	resp := doIssue(t, a, "3.3.3.3", map[string]any{"fingerprint": "fp-failopen"})
	if !resp.OK || resp.Token == "" {
		t.Fatalf("balance check failure must fail-OPEN and still mint: %+v", resp)
	}
	if m.createCalls != 1 {
		t.Fatalf("fail-open should mint once, createCalls=%d", m.createCalls)
	}
}

func TestHandleIssue_HappyPathAndAuthHeaders(t *testing.T) {
	m := newMockNewAPI()
	defer m.close()
	a := newTestApp(t, m.srv.URL)

	resp := doIssue(t, a, "4.4.4.4", map[string]any{"fingerprint": "deadbeefCAFE", "source": "powerkey", "os": "darwin"})
	if !resp.OK || !strings.HasPrefix(resp.Token, "sk-key-") {
		t.Fatalf("happy path mint failed: %+v", resp)
	}
	if resp.BaseURL != a.cfg.publicBase || resp.Model != a.cfg.model || resp.QuotaUSD != a.cfg.quotaUSD {
		t.Fatalf("response fields mismatch: %+v", resp)
	}
	if m.createCalls != 1 || m.keyCalls != 1 || m.selfCalls != 1 {
		t.Fatalf("expected 1 self+create+key, got self=%d create=%d key=%d", m.selfCalls, m.createCalls, m.keyCalls)
	}
	// 双头契约：以总账号 access_token + New-Api-User 调 new-api。
	if m.gotAuth != a.cfg.umbrellaToken || m.gotUser != a.cfg.umbrellaUser {
		t.Fatalf("auth headers mismatch: auth=%q user=%q", m.gotAuth, m.gotUser)
	}
	// 复用持久化：同指纹再来不应重铸。
	resp2 := doIssue(t, a, "4.4.4.4", map[string]any{"fingerprint": "deadbeefCAFE"})
	if !resp2.OK || m.createCalls != 1 {
		t.Fatalf("second call should reuse, not re-mint: resp=%+v createCalls=%d", resp2, m.createCalls)
	}
}

// TestHandleIssue_TrustedIPRateLimit 证明限流按 XFF「末跳」而非可伪造的 XFF[0] 计数。
func TestHandleIssue_TrustedIPRateLimit(t *testing.T) {
	t.Run("same last hop, spoofed first -> shares limit", func(t *testing.T) {
		m := newMockNewAPI()
		defer m.close()
		a := newTestApp(t, m.srv.URL)
		a.cfg.ratePerIPDay = 1
		r1 := doIssue(t, a, "1.1.1.1, 9.9.9.9", map[string]any{"fingerprint": "fp-1"})
		r2 := doIssue(t, a, "2.2.2.2, 9.9.9.9", map[string]any{"fingerprint": "fp-2"})
		if !r1.OK {
			t.Fatalf("first should pass: %+v", r1)
		}
		if r2.OK || r2.Reason != "rate_limited" {
			t.Fatalf("same trusted last-hop must share the cap (spoofed XFF[0] ignored): %+v", r2)
		}
	})
	t.Run("different last hop -> independent limits", func(t *testing.T) {
		m := newMockNewAPI()
		defer m.close()
		a := newTestApp(t, m.srv.URL)
		a.cfg.ratePerIPDay = 1
		r1 := doIssue(t, a, "9.9.9.9", map[string]any{"fingerprint": "fp-3"})
		r2 := doIssue(t, a, "8.8.8.8", map[string]any{"fingerprint": "fp-4"})
		if !r1.OK || !r2.OK {
			t.Fatalf("distinct trusted client IPs must not share the cap: r1=%+v r2=%+v", r1, r2)
		}
	})
}

func TestHandleIssue_SharedSecretGate(t *testing.T) {
	m := newMockNewAPI()
	defer m.close()
	a := newTestApp(t, m.srv.URL)
	a.cfg.issueSecret = "s3cr3t"

	// 缺/错头 → 拒绝，且不触达任何 new-api 调用。
	bad := doIssue(t, a, "5.5.5.5", map[string]any{"fingerprint": "fp-secret"})
	if bad.OK || bad.Reason != "unauthorized" {
		t.Fatalf("missing secret must be rejected: %+v", bad)
	}
	if m.selfCalls != 0 || m.createCalls != 0 {
		t.Fatalf("rejected request must not call new-api: self=%d create=%d", m.selfCalls, m.createCalls)
	}

	// 带正确头 → 放行铸码。
	r := httptest.NewRequest(http.MethodPost, "/issue", strings.NewReader(`{"fingerprint":"fp-secret"}`))
	r.RemoteAddr = "10.0.0.1:5555"
	r.Header.Set("X-Forwarded-For", "5.5.5.5")
	r.Header.Set(issueSecretHeader, "s3cr3t")
	rec := httptest.NewRecorder()
	a.handleIssue(rec, r)
	var ok issueResp
	if err := json.Unmarshal(rec.Body.Bytes(), &ok); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !ok.OK || ok.Token == "" {
		t.Fatalf("correct secret should mint: %+v (status=%d)", ok, rec.Code)
	}
}

func TestHandleIssue_BadRequest(t *testing.T) {
	m := newMockNewAPI()
	defer m.close()
	a := newTestApp(t, m.srv.URL)
	resp := doIssue(t, a, "6.6.6.6", map[string]any{"os": "darwin"}) // no fingerprint
	if resp.OK || resp.Reason != "bad_request" {
		t.Fatalf("missing fingerprint should be bad_request: %+v", resp)
	}
}
