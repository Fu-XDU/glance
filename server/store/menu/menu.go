package menu

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"glance/store/binance"
)

const (
	defaultConfigPath = "config/menu.json"
	titleTimeLayout   = "15:04"
)

var (
	configPath          = defaultConfigPath
	configPathOnce      sync.Once
	templatePlaceholder = regexp.MustCompile(`\{\{([A-Za-z0-9_:{.-]{2,40})\}\}`)
	reservedPlaceholders  = map[string]struct{}{
		"time": {}, "date": {}, "datetime": {}, "btc_price": {},
	}
)

// Item 与 macOS 客户端 MenuItem 字段对应。
type Item struct {
	Title       string  `json:"title"`
	Action      *string `json:"action,omitempty"`
	Value       *string `json:"value,omitempty"`
	StatusTitle *string `json:"status_title,omitempty"`
	Children    []Item  `json:"children,omitempty"`
}

// BinanceSettings 币安相关配置，写在 menu.json 的 binance 字段中。
type BinanceSettings struct {
	Symbols              json.RawMessage `json:"symbols,omitempty"`
	APIKey               string          `json:"api_key,omitempty"`
	APISecret            string          `json:"api_secret,omitempty"`
	BaseURL              string          `json:"base_url,omitempty"`
	FuturesBaseURL       string          `json:"futures_base_url,omitempty"`
	FetchIntervalSeconds *int            `json:"fetch_interval_seconds,omitempty"`
}

// Config 菜单配置文件结构。
type Config struct {
	Title               string           `json:"title"`
	RefreshAfterSeconds *int             `json:"refresh_after_seconds,omitempty"`
	Binance             *BinanceSettings `json:"binance,omitempty"`
	Symbols             []string         `json:"symbols,omitempty"` // 兼容旧配置
	Menu                []Item           `json:"menu"`
}

// Response GET /api/menu 响应体。
type Response struct {
	Title               string `json:"title"`
	RefreshAfterSeconds *int   `json:"refresh_after_seconds,omitempty"`
	Menu                []Item `json:"menu"`
}

// SetConfigPath 设置菜单配置文件路径（进程内仅生效一次）。
func SetConfigPath(path string) {
	configPathOnce.Do(func() {
		if path != "" {
			configPath = path
		}
	})
}

func ConfigPath() string {
	return configPath
}

// LoadBinanceConfig 从 menu.json 读取币安配置。
func LoadBinanceConfig() (binance.Config, error) {
	cfg, err := loadConfig()
	if err != nil {
		return binance.Config{}, err
	}

	out := binance.Config{}
	if cfg.Binance != nil {
		out.APIKey = cfg.Binance.APIKey
		out.APISecret = cfg.Binance.APISecret
		out.BaseURL = cfg.Binance.BaseURL
		out.FuturesBaseURL = cfg.Binance.FuturesBaseURL
		if cfg.Binance.FetchIntervalSeconds != nil {
			out.FetchInterval = time.Duration(*cfg.Binance.FetchIntervalSeconds) * time.Second
		}
	}

	out.Symbols, err = collectSymbolSpecs(cfg)
	if err != nil {
		return binance.Config{}, err
	}
	if len(out.Symbols) == 0 {
		out.Symbols = []binance.SymbolSpec{{Symbol: "BTCUSDT", Market: binance.MarketSpot}}
	}

	return out, nil
}

func loadConfig() (*Config, error) {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	if cfg.Title == "" {
		cfg.Title = "Glance"
	}
	return &cfg, nil
}

// LoadResponse 读取配置并渲染动态 title / 菜单项模板。
func LoadResponse() (*Response, error) {
	cfg, err := loadConfig()
	if err != nil {
		return nil, err
	}
	ctx := newTemplateContext()
	return &Response{
		Title:               renderTemplate(cfg.Title, ctx),
		RefreshAfterSeconds: cfg.RefreshAfterSeconds,
		Menu:                renderItems(cfg.Menu, ctx),
	}, nil
}

type templateContext struct {
	prices map[string]string
}

func newTemplateContext() *templateContext {
	return &templateContext{prices: make(map[string]string)}
}

func (c *templateContext) getPrice(query string) string {
	query = strings.TrimSpace(query)
	if price, ok := c.prices[query]; ok {
		return price
	}
	price := binance.Price(query)
	c.prices[query] = price
	return price
}

func renderItems(items []Item, ctx *templateContext) []Item {
	out := make([]Item, len(items))
	for i, item := range items {
		out[i] = renderItem(item, ctx)
	}
	return out
}

func renderItem(item Item, ctx *templateContext) Item {
	out := Item{Title: renderTemplate(item.Title, ctx)}
	if item.Action != nil {
		action := renderTemplate(*item.Action, ctx)
		out.Action = &action
		if *item.Action == "select" && item.Value != nil {
			price := ctx.getPrice(*item.Value)
			out.StatusTitle = &price
		}
	}
	if item.Value != nil {
		value := renderTemplate(*item.Value, ctx)
		out.Value = &value
	}
	if len(item.Children) > 0 {
		out.Children = renderItems(item.Children, ctx)
	}
	return out
}

func renderTemplate(text string, ctx *templateContext) string {
	if !strings.Contains(text, "{{") {
		return text
	}

	now := time.Now()
	replacements := map[string]string{
		"{{time}}":     now.Format(titleTimeLayout),
		"{{date}}":     now.Format("2006-01-02"),
		"{{datetime}}": now.Format("2006-01-02 15:04"),
	}
	for _, key := range binance.Symbols() {
		placeholder := "{{" + key + "}}"
		if strings.Contains(text, placeholder) {
			replacements[placeholder] = ctx.getPrice(key)
		}
	}
	for _, match := range templatePlaceholder.FindAllStringSubmatch(text, -1) {
		name := strings.ToLower(match[1])
		if _, reserved := reservedPlaceholders[name]; reserved {
			continue
		}
		if _, ok := replacements[match[0]]; ok {
			continue
		}
		replacements[match[0]] = ctx.getPrice(match[1])
	}
	if strings.Contains(text, "{{btc_price}}") {
		replacements["{{btc_price}}"] = ctx.getPrice("BTCUSDT")
	}

	out := text
	for placeholder, value := range replacements {
		out = strings.ReplaceAll(out, placeholder, value)
	}
	return out
}
