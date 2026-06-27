// powerkey-issuer — 薄发码服务
//
// 客户端 POST /issue {fingerprint,os,arch,source,channel,client_version}
//
//	成功 -> {ok:true, token, base_url, model, quota_usd}
//	降级 -> {ok:false, fallback_url, reason, message}
//
// 在一个「体验」总账号下，经 apiget(new-api) 的用户级 token API 铸一个作用域子 token：
//
//	POST /api/token/            创建（不回 key）
//	GET  /api/token/search      按 name 找回 id
//	POST /api/token/:id/key     取完整 key
//
// 鉴权 = 总账号的 Authorization:<access_token> + New-Api-User:<id> 双头。
//
// 防刷：L1 指纹去重（同指纹复用同一 token，不重铸）+ 每 IP 每日上限（超限降级到网页自助）。
// 本地 store 只存 fingerprint->token id（不落 key），复用时按 id 重新取 key —— 服务端无 key 静置。
//
// ⚠ 部署前用 prod 冒烟核实 apiget 返回体形状（ApiSuccess 包裹 / pageInfo.items），解析已尽量防御。
package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const quotaPerUnit = 500000 // 1 USD = 500000 quota（与 new-api common.QuotaPerUnit 对齐）

const issueSecretHeader = "X-Powerkey-Secret" // 可选共享密钥头名（配合 ISSUE_SHARED_SECRET，默认关闭）

// ---------------- 配置 ----------------

type config struct {
	listen         string
	adminBase      string // apiget admin/user API base：docker 内 http://new-api:3000，或 https://api.apiget.cc
	umbrellaToken  string // 体验总账号 access_token（系统访问令牌，非网关 key）
	umbrellaUser   string // 体验总账号 user id（New-Api-User 头）
	publicBase     string // 回给客户端的 base_url（https://api.apiget.cc）
	model          string // 默认试用模型
	group          string // token 分组（""=随总账号默认）
	quotaUSD       float64
	fallbackURL    string
	ratePerIPDay   int
	trustXFFDepth  int     // 受信代理层数：取 XFF 末 N 跳为真实客户端（BWH Caddy→SG 链路 = 1）；0=只用 RemoteAddr
	minUmbrellaUSD float64 // 总账号剩余额度 < 此值(USD) 则拒铸、降级网页自助；默认 2× 试用额度
	issueSecret    string  // 可选共享密钥（""=关闭）：开启后 /issue 必须带匹配头，挡公网直 POST
	storePath      string
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func loadConfig() (*config, error) {
	c := &config{
		listen:        env("LISTEN_ADDR", ":8800"),
		adminBase:     strings.TrimRight(env("APIGET_ADMIN_BASE", "http://new-api:3000"), "/"),
		umbrellaToken: os.Getenv("UMBRELLA_ACCESS_TOKEN"),
		umbrellaUser:  os.Getenv("UMBRELLA_USER_ID"),
		publicBase:    strings.TrimRight(env("PUBLIC_BASE_URL", "https://api.apiget.cc"), "/"),
		model:         env("TRIAL_MODEL", "deepseek-v4-pro"),
		group:         env("TRIAL_GROUP", ""),
		fallbackURL:   env("FALLBACK_URL", "https://apiget.cc/register?ref=powerkey"),
		storePath:     env("STORE_PATH", "./issued.json"),
		quotaUSD:      mustFloat(env("TRIAL_QUOTA_USD", "2")),
		ratePerIPDay:  mustInt(env("RATE_LIMIT_PER_IP_PER_DAY", "20")),
		trustXFFDepth: mustInt(env("TRUST_XFF_DEPTH", "1")),
		issueSecret:   os.Getenv("ISSUE_SHARED_SECRET"),
	}
	// 总账号余额护栏阈值（USD）：默认 = 2× 试用发放额度。
	if v := os.Getenv("MIN_UMBRELLA_QUOTA"); v != "" {
		c.minUmbrellaUSD = mustFloat(v)
	} else {
		c.minUmbrellaUSD = 2 * c.quotaUSD
	}
	if c.umbrellaToken == "" || c.umbrellaUser == "" {
		return nil, errors.New("UMBRELLA_ACCESS_TOKEN 和 UMBRELLA_USER_ID 必填")
	}
	return c, nil
}

func mustFloat(s string) float64 { var f float64; fmt.Sscanf(s, "%f", &f); return f }
func mustInt(s string) int       { var n int; fmt.Sscanf(s, "%d", &n); return n }

// ---------------- 持久化（fingerprint -> token id，不存 key） ----------------

type issuedRec struct {
	ID       int     `json:"id"`
	Model    string  `json:"model"`
	QuotaUSD float64 `json:"quota_usd"`
	Source   string  `json:"source"`
	Channel  string  `json:"channel"`
	IssuedAt int64   `json:"issued_at"`
}

type store struct {
	mu   sync.Mutex
	path string
	recs map[string]issuedRec
}

func newStore(path string) *store {
	s := &store{path: path, recs: map[string]issuedRec{}}
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &s.recs)
	}
	return s
}

func (s *store) get(fp string) (issuedRec, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.recs[fp]
	return r, ok
}

func (s *store) put(fp string, r issuedRec) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.recs[fp] = r
	b, _ := json.MarshalIndent(s.recs, "", "  ")
	tmp := s.path + ".tmp"
	if os.WriteFile(tmp, b, 0o600) == nil {
		_ = os.Rename(tmp, s.path)
	}
}

// ---------------- 每 IP 每日限流 ----------------

type ipLimiter struct {
	mu    sync.Mutex
	day   string
	count map[string]int
}

func newIPLimiter() *ipLimiter { return &ipLimiter{count: map[string]int{}} }

func (l *ipLimiter) allow(ip string, max int) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	today := time.Now().UTC().Format("2006-01-02")
	if today != l.day {
		l.day = today
		l.count = map[string]int{}
	}
	if l.count[ip] >= max {
		return false
	}
	l.count[ip]++
	return true
}

// ---------------- 应用 ----------------

type app struct {
	cfg   *config
	http  *http.Client
	store *store
	ipl   *ipLimiter
}

type issueReq struct {
	Fingerprint   string `json:"fingerprint"`
	OS            string `json:"os"`
	Arch          string `json:"arch"`
	Source        string `json:"source"`
	Channel       string `json:"channel"`
	ClientVersion string `json:"client_version"`
}

type issueResp struct {
	OK          bool    `json:"ok"`
	Token       string  `json:"token,omitempty"`
	BaseURL     string  `json:"base_url,omitempty"`
	Model       string  `json:"model,omitempty"`
	QuotaUSD    float64 `json:"quota_usd,omitempty"`
	FallbackURL string  `json:"fallback_url,omitempty"`
	Reason      string  `json:"reason,omitempty"`
	Message     string  `json:"message,omitempty"`
}

// adminCall 以总账号身份调用 apiget 用户级 API。
func (a *app) adminCall(method, path string, body any) (map[string]any, error) {
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, a.cfg.adminBase+path, rdr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", a.cfg.umbrellaToken)
	req.Header.Set("New-Api-User", a.cfg.umbrellaUser)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := a.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out map[string]any
	dec, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	_ = json.Unmarshal(dec, &out)
	if resp.StatusCode != http.StatusOK {
		return out, fmt.Errorf("admin %s %s -> HTTP %d", method, path, resp.StatusCode)
	}
	if ok, present := out["success"].(bool); present && !ok {
		return out, fmt.Errorf("admin %s %s -> success=false: %v", method, path, out["message"])
	}
	return out, nil
}

// dataMap 取响应里的 data（兼容 {success,data} / {code,data} 形状）。
func dataMap(out map[string]any) map[string]any {
	if d, ok := out["data"].(map[string]any); ok {
		return d
	}
	return nil
}

func (a *app) mint(name string) (int, error) {
	body := map[string]any{
		"name":                 name,
		"remain_quota":         int(a.cfg.quotaUSD * quotaPerUnit),
		"expired_time":         -1, // 不限时
		"unlimited_quota":      false,
		"model_limits_enabled": false, // 不锁模型
		"model_limits":         "",
		"group":                a.cfg.group,
	}
	if _, err := a.adminCall("POST", "/api/token/", body); err != nil {
		return 0, err
	}
	return a.findTokenID(name)
}

func (a *app) findTokenID(name string) (int, error) {
	out, err := a.adminCall("GET", "/api/token/search?keyword="+url.QueryEscape(name), nil)
	if err != nil {
		return 0, err
	}
	d := dataMap(out)
	var items []any
	if d != nil {
		items, _ = d["items"].([]any)
	}
	if items == nil { // 兼容 data 直接是数组的形状
		items, _ = out["data"].([]any)
	}
	for _, it := range items {
		m, _ := it.(map[string]any)
		if m != nil && m["name"] == name {
			if idf, ok := m["id"].(float64); ok {
				return int(idf), nil
			}
		}
	}
	return 0, errors.New("创建后未按 name 找回 token id（核实 search 返回体形状）")
}

func (a *app) fetchKey(id int) (string, error) {
	out, err := a.adminCall("POST", fmt.Sprintf("/api/token/%d/key", id), nil)
	if err != nil {
		return "", err
	}
	if d := dataMap(out); d != nil {
		if k, _ := d["key"].(string); k != "" {
			return k, nil
		}
	}
	if k, _ := out["key"].(string); k != "" {
		return k, nil
	}
	return "", errors.New("GetTokenKey 未返回 key（核实返回体形状）")
}

// umbrellaRemainingUSD 读总账号剩余额度(USD)。
// 来源（已对源码核实）：GET {adminBase}/api/user/self —— new-api router/api-router.go
// selfRoute GET /self → controller.GetSelf，UserAuth 接受总账号 access_token + New-Api-User
// 双头（与本服务 adminCall 同），响应 {success,message,data:{...,"quota":<int>,...}}；data.quota
// = user.Quota（quota 单位，quotaPerUnit/USD），且随消费递减（service/pre_consume_quota.go、
// service/quota.go），故反映所有试用 token 的共享剩余预算。known=false=没读到可信数值。
func (a *app) umbrellaRemainingUSD() (usd float64, known bool, err error) {
	out, err := a.adminCall("GET", "/api/user/self", nil)
	if err != nil {
		return 0, false, err
	}
	d := dataMap(out)
	if d == nil {
		return 0, false, errors.New("user/self 无 data 对象")
	}
	q, ok := d["quota"].(float64) // JSON 数字解到 map[string]any 即 float64
	if !ok {
		return 0, false, errors.New("user/self data.quota 缺失或非数值")
	}
	return q / quotaPerUnit, true, nil
}

// clientIP 返回用于限流的可信客户端 IP。
// trustDepth = 受信代理层数：链路是 端用户 → BWH Caddy → SG issuer，Caddy 把真实端用户作为
// X-Forwarded-For 的「末跳」追加，故 depth=1 取 XFF 倒数第 1 个。XFF[0] 可被客户端伪造，绝不
// 可信。depth<=0 或 XFF 跳数不足 → 退回 RemoteAddr。
func clientIP(r *http.Request, trustDepth int) string {
	if trustDepth > 0 {
		if xf := r.Header.Get("X-Forwarded-For"); xf != "" {
			parts := strings.Split(xf, ",")
			if idx := len(parts) - trustDepth; idx >= 0 && idx < len(parts) {
				if ip := strings.TrimSpace(parts[idx]); ip != "" {
					return ip
				}
			}
		}
	}
	h := r.RemoteAddr
	if i := strings.LastIndex(h, ":"); i > 0 {
		return h[:i]
	}
	return h
}

func mask(tok string) string {
	if len(tok) <= 8 {
		return "****"
	}
	return tok[:6] + "****"
}

func (a *app) handleIssue(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, issueResp{OK: false, Reason: "method", Message: "POST only"})
		return
	}
	// 可选共享密钥闸门（ISSUE_SHARED_SECRET 未设=关闭，当前 get.apiget.cc 流程不受影响）。
	// 开启后 /issue 必须带匹配的 X-Powerkey-Secret 头 → 挡掉绕过 Caddy 的公网直 POST。常数时间比较防时序探测。
	if a.cfg.issueSecret != "" &&
		subtle.ConstantTimeCompare([]byte(r.Header.Get(issueSecretHeader)), []byte(a.cfg.issueSecret)) != 1 {
		writeJSON(w, http.StatusUnauthorized, issueResp{OK: false, Reason: "unauthorized", Message: "unauthorized"})
		return
	}
	var req issueReq
	body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
	if json.Unmarshal(body, &req) != nil || strings.TrimSpace(req.Fingerprint) == "" {
		writeJSON(w, http.StatusBadRequest, issueResp{OK: false, Reason: "bad_request", Message: "fingerprint required"})
		return
	}
	fp := req.Fingerprint

	// L1：同指纹复用（不重铸）；按 id 重新取 key，服务端不存 key。
	if rec, ok := a.store.get(fp); ok {
		if key, err := a.fetchKey(rec.ID); err == nil {
			writeJSON(w, http.StatusOK, issueResp{OK: true, Token: key, BaseURL: a.cfg.publicBase, Model: rec.Model, QuotaUSD: rec.QuotaUSD})
			return
		}
		// 复用失败（token 可能被删）→ 落到重新铸造
	}

	// 每 IP 每日上限 → 降级网页自助（先走廉价的内存限流，再做上游余额检查）
	if !a.ipl.allow(clientIP(r, a.cfg.trustXFFDepth), a.cfg.ratePerIPDay) {
		writeJSON(w, http.StatusOK, issueResp{OK: false, Reason: "rate_limited", FallbackURL: a.cfg.fallbackURL,
			Message: "今日体验额度领取已达上限，请稍后或网页自助领取。"})
		return
	}

	// 总账号余额护栏（最高优先级）：余额耗尽时新铸的是「死 token」，且消费同账号 user.Quota 会
	// 连带拖垮已发放的试用 → 宁可降级。**故意 fail-OPEN**：余额检查本身出错/不确定时仍照常铸码
	// （不破坏 happy path），仅打 WARN 供监控——选这个方向是因为铸码主流程可用性优先于护栏。
	if usd, known, err := a.umbrellaRemainingUSD(); err != nil || !known {
		log.Printf("WARN umbrella_balance_check_failed (fail-open, minting anyway): %v", err)
	} else if usd < a.cfg.minUmbrellaUSD {
		log.Printf("WARN umbrella_balance_low remaining=$%.2f threshold=$%.2f — refusing mint, serving fallback", usd, a.cfg.minUmbrellaUSD)
		writeJSON(w, http.StatusOK, issueResp{OK: false, Reason: "umbrella_exhausted", FallbackURL: a.cfg.fallbackURL,
			Message: "体验额度暂时不可用，请网页自助领取。"})
		return
	}

	name := "powerkey-" + safeName(fp)
	id, err := a.mint(name)
	if err != nil {
		log.Printf("mint failed fp=%s src=%s: %v", mask(fp), req.Source, err)
		writeJSON(w, http.StatusOK, issueResp{OK: false, Reason: "mint_failed", FallbackURL: a.cfg.fallbackURL,
			Message: "发码暂时不可用，请网页自助领取。"})
		return
	}
	key, err := a.fetchKey(id)
	if err != nil {
		log.Printf("fetchKey failed id=%d: %v", id, err)
		writeJSON(w, http.StatusOK, issueResp{OK: false, Reason: "key_failed", FallbackURL: a.cfg.fallbackURL,
			Message: "发码暂时不可用，请网页自助领取。"})
		return
	}
	a.store.put(fp, issuedRec{ID: id, Model: a.cfg.model, QuotaUSD: a.cfg.quotaUSD,
		Source: req.Source, Channel: req.Channel, IssuedAt: time.Now().Unix()})
	// 归因日志（不打印 key/原始指纹）
	log.Printf("issued id=%d token=%s os=%s source=%s channel=%s", id, mask(key), req.OS, req.Source, req.Channel)
	writeJSON(w, http.StatusOK, issueResp{OK: true, Token: key, BaseURL: a.cfg.publicBase, Model: a.cfg.model, QuotaUSD: a.cfg.quotaUSD})
}

// safeName 把指纹哈希截断为 token name 用片段（<=50 字符，AddToken 限制）。
func safeName(fp string) string {
	keep := strings.Map(func(r rune) rune {
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') {
			return r
		}
		return -1
	}, strings.ToLower(fp))
	if len(keep) > 24 {
		keep = keep[:24]
	}
	return keep
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	a := &app{
		cfg:   cfg,
		http:  &http.Client{Timeout: 20 * time.Second},
		store: newStore(cfg.storePath),
		ipl:   newIPLimiter(),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/issue", a.handleIssue)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "ok") })
	log.Printf("powerkey-issuer listening on %s (adminBase=%s model=%s quota=$%.0f minUmbrella=$%.0f trustXFFDepth=%d secretGate=%v)",
		cfg.listen, cfg.adminBase, cfg.model, cfg.quotaUSD, cfg.minUmbrellaUSD, cfg.trustXFFDepth, cfg.issueSecret != "")
	log.Fatal(http.ListenAndServe(cfg.listen, mux))
}
