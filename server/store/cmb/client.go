package cmb

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/labstack/gommon/log"
)

const (
	defaultURL          = "https://fx.cmbchina.com/api/v1/fx/rate"
	defaultFetchInterval = 60 * time.Second
)

// Config 招商银行外汇拉取配置。
type Config struct {
	URL           string
	FetchInterval time.Duration
	Enabled       bool
}

type rateEntry struct {
	Name     string // 美元
	Code     string // USD
	Mid      string // rtbBid 参考/中间
	SpotBid  string // rtcBid 现汇买入
	SpotAsk  string // rtcOfr 现汇卖出
	CashBid  string // rthBid 现钞买入
	CashAsk  string // rthOfr 现钞卖出
	Unit     string // ccyExc
	Updated  string // ratDat + ratTim
}

var (
	cfg Config

	mu    sync.RWMutex
	rates map[string]rateEntry // keyed by uppercase currency code

	httpClient = &http.Client{Timeout: 8 * time.Second}
)

// Configure 设置招行外汇客户端。
func Configure(c Config) {
	if c.URL == "" {
		c.URL = defaultURL
	}
	if c.FetchInterval <= 0 {
		c.FetchInterval = defaultFetchInterval
	}
	cfg = c
	mu.Lock()
	rates = make(map[string]rateEntry)
	mu.Unlock()
	if !cfg.Enabled {
		log.Info("cmb fx fetch disabled")
		return
	}
	log.Infof("cmb fx configured: url=%s interval=%s", cfg.URL, cfg.FetchInterval)
}

// Start 启动后台定时拉取。
func Start() {
	if !cfg.Enabled {
		return
	}
	refresh()
	go func() {
		ticker := time.NewTicker(cfg.FetchInterval)
		defer ticker.Stop()
		for range ticker.C {
			refresh()
		}
	}()
}

// IsQuery 判断模板占位符是否为招行外汇查询，如 fx:USD / fx:USD_bid。
func IsQuery(query string) bool {
	q := strings.ToLower(strings.TrimSpace(query))
	return strings.HasPrefix(q, "fx:")
}

// Rate 返回格式化汇率；query 如 "fx:USD"、"fx:USD_bid"、"fx:EUR_ask"。
func Rate(query string) string {
	code, field := parseQuery(query)
	if code == "" {
		return "--"
	}
	mu.RLock()
	defer mu.RUnlock()
	entry, ok := rates[code]
	if !ok {
		return "--"
	}
	switch field {
	case "bid", "spot_bid":
		return displayOrDash(entry.SpotBid)
	case "ask", "spot_ask", "":
		return displayOrDash(entry.SpotAsk)
	case "mid":
		return displayOrDash(entry.Mid)
	case "cash_bid":
		return displayOrDash(entry.CashBid)
	case "cash_ask":
		return displayOrDash(entry.CashAsk)
	case "name":
		if entry.Name != "" {
			return entry.Name
		}
		return code
	default:
		return displayOrDash(entry.SpotAsk)
	}
}

// FormatRateLines 返回纯文本汇率行，格式为 "USD: 卖价/买价"（按币种排序）。
func FormatRateLines() []string {
	mu.RLock()
	defer mu.RUnlock()
	if len(rates) == 0 {
		return nil
	}
	codes := make([]string, 0, len(rates))
	for code := range rates {
		codes = append(codes, code)
	}
	sort.Strings(codes)
	out := make([]string, 0, len(codes))
	for _, code := range codes {
		entry := rates[code]
		out = append(out, fmt.Sprintf("%s: %s/%s", code, displayOrDash(entry.SpotAsk), displayOrDash(entry.SpotBid)))
	}
	return out
}

func displayOrDash(v string) string {
	if strings.TrimSpace(v) == "" {
		return "--"
	}
	return v
}

func parseQuery(query string) (code, field string) {
	query = strings.TrimSpace(query)
	if query == "" {
		return "", ""
	}
	lower := strings.ToLower(query)
	if !strings.HasPrefix(lower, "fx:") {
		return "", ""
	}
	rest := strings.TrimSpace(query[3:])
	if rest == "" {
		return "", ""
	}
	parts := strings.SplitN(rest, "_", 2)
	code = strings.ToUpper(strings.TrimSpace(parts[0]))
	if len(parts) == 2 {
		field = strings.ToLower(strings.TrimSpace(parts[1]))
	}
	return code, field
}

type apiResponse struct {
	ReturnCode string          `json:"returnCode"`
	ErrorMsg   *string         `json:"errorMsg"`
	Body       []apiRateRecord `json:"body"`
}

type apiRateRecord struct {
	CcyNbr    string `json:"ccyNbr"`
	CcyNbrEng string `json:"ccyNbrEng"`
	RtbBid    string `json:"rtbBid"`
	RthOfr    string `json:"rthOfr"`
	RtcOfr    string `json:"rtcOfr"`
	RthBid    string `json:"rthBid"`
	RtcBid    string `json:"rtcBid"`
	RatTim    string `json:"ratTim"`
	RatDat    string `json:"ratDat"`
	CcyExc    string `json:"ccyExc"`
}

func refresh() {
	next, err := fetchRates()
	if err != nil {
		log.Errorf("cmb fx fetch failed: %v", err)
		return
	}
	mu.Lock()
	rates = next
	mu.Unlock()
	log.Infof("cmb fx refreshed: %d currencies", len(next))
}

func fetchRates() (map[string]rateEntry, error) {
	req, err := http.NewRequest(http.MethodGet, cfg.URL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Glance/1.0")
	req.Header.Set("Accept", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("cmb fx status %d: %s", resp.StatusCode, string(body))
	}

	var payload apiResponse
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, err
	}
	if payload.ReturnCode != "" && payload.ReturnCode != "SUC0000" {
		msg := payload.ReturnCode
		if payload.ErrorMsg != nil {
			msg = *payload.ErrorMsg
		}
		return nil, fmt.Errorf("cmb fx api error: %s", msg)
	}

	out := make(map[string]rateEntry, len(payload.Body))
	for _, row := range payload.Body {
		code := extractCurrencyCode(row.CcyNbrEng)
		if code == "" {
			continue
		}
		out[code] = rateEntry{
			Name:    row.CcyNbr,
			Code:    code,
			Mid:     row.RtbBid,
			SpotBid: row.RtcBid,
			SpotAsk: row.RtcOfr,
			CashBid: row.RthBid,
			CashAsk: row.RthOfr,
			Unit:    row.CcyExc,
			Updated: strings.TrimSpace(row.RatDat + " " + row.RatTim),
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("cmb fx empty rates")
	}
	return out, nil
}

// extractCurrencyCode 从 "美元 USD" / "USD" 提取币种代码。
func extractCurrencyCode(eng string) string {
	eng = strings.TrimSpace(eng)
	if eng == "" {
		return ""
	}
	fields := strings.Fields(eng)
	for i := len(fields) - 1; i >= 0; i-- {
		token := strings.ToUpper(fields[i])
		if len(token) == 3 && isAlpha(token) {
			return token
		}
	}
	return ""
}

func isAlpha(s string) bool {
	for _, r := range s {
		if r < 'A' || r > 'Z' {
			return false
		}
	}
	return true
}
