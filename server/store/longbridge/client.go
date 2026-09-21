package longbridge

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"glance/store/symbol"

	"github.com/labstack/gommon/log"
	lbconfig "github.com/longbridge/openapi-go/config"
	"github.com/longbridge/openapi-go/quote"
)

const (
	defaultQuoteTimeout  = 8 * time.Second
	defaultFetchInterval = 10 * time.Second
)

// Config LongBridge 行情配置。凭证空字段回退到环境变量。
type Config struct {
	AppKey        string
	AppSecret     string
	AccessToken   string
	Region        string
	Symbols       []symbol.Spec
	FetchInterval time.Duration
}

type quoteClient interface {
	Quote(ctx context.Context, symbols []string) ([]*quote.SecurityQuote, error)
	Close() error
}

var (
	cfg Config

	clientMu sync.Mutex
	client   quoteClient

	newQuoteClient = connectQuoteClient

	mu           sync.RWMutex
	displayPrice map[string]string
	lastUpdated  time.Time
)

// Configure 保存 LongBridge 配置（进程启动时调用一次）。
func Configure(c Config) {
	clientMu.Lock()
	if client != nil {
		_ = client.Close()
		client = nil
	}
	clientMu.Unlock()

	if c.FetchInterval <= 0 {
		c.FetchInterval = defaultFetchInterval
	}
	c.Symbols = symbol.NormalizeSpecs(c.Symbols)
	cfg = c

	mu.Lock()
	displayPrice = make(map[string]string, len(cfg.Symbols))
	mu.Unlock()

	for _, spec := range cfg.Symbols {
		log.Infof("longbridge symbol configured: %s (%s)", spec.Symbol, spec.Market)
	}
}

// SymbolSpecs 返回当前配置的标的列表。
func SymbolSpecs() []symbol.Spec {
	out := make([]symbol.Spec, len(cfg.Symbols))
	copy(out, cfg.Symbols)
	return out
}

// Symbols 返回模板占位符列表。
func Symbols() []string {
	return symbol.TemplateKeys(SymbolSpecs())
}

// Owns 当前 LongBridge 配置是否包含该 query 对应的标的。
func Owns(query string) bool {
	return symbol.Owns(query, cfg.Symbols)
}

// Price 返回内存中的格式化价格；query 可为 "stocks:GOOG.US" 或 "GOOG.US"。
func Price(query string) string {
	spec := symbol.ResolveSpec(query, cfg.Symbols)
	if spec.Symbol == "" {
		return "--"
	}
	mu.RLock()
	defer mu.RUnlock()
	if price, ok := displayPrice[spec.CacheKey()]; ok && price != "" {
		return price
	}
	return "--"
}

// Start 启动后台定时拉取。无标的时不连接。
func Start() {
	if len(cfg.Symbols) == 0 {
		return
	}
	refreshPrices()
	go func() {
		ticker := time.NewTicker(cfg.FetchInterval)
		defer ticker.Stop()
		for range ticker.C {
			refreshPrices()
		}
	}()
}

func refreshPrices() {
	if len(cfg.Symbols) == 0 {
		return
	}
	symbols := make([]string, len(cfg.Symbols))
	for i, spec := range cfg.Symbols {
		symbols[i] = spec.Symbol
	}

	ctx, cancel := context.WithTimeout(context.Background(), defaultQuoteTimeout)
	defer cancel()
	prices, err := FetchQuotes(ctx, symbols)
	if err != nil {
		log.Errorf("longbridge price fetch failed: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	lastUpdated = time.Now()
	for _, spec := range cfg.Symbols {
		key := spec.CacheKey()
		raw := ""
		if prices != nil {
			raw = prices[spec.Symbol]
		}
		if raw == "" {
			if displayPrice[key] == "" {
				displayPrice[key] = "--"
			}
			continue
		}
		displayPrice[key] = symbol.FormatPrice(raw)
		log.Infof("%v: %v", key, displayPrice[key])
	}
}

// FetchQuotes 按配置中的 symbol 原样向 LongBridge 询价，不做后缀改写。
func FetchQuotes(ctx context.Context, symbols []string) (map[string]string, error) {
	out := make(map[string]string, len(symbols))
	if len(symbols) == 0 {
		return out, nil
	}

	qctx, err := ensureClient()
	if err != nil {
		return nil, err
	}

	quoteSymbols := make([]string, 0, len(symbols))
	seen := make(map[string]struct{}, len(symbols))
	for _, symbol := range symbols {
		symbol = strings.ToUpper(strings.TrimSpace(symbol))
		if symbol == "" {
			continue
		}
		if _, ok := seen[symbol]; ok {
			continue
		}
		seen[symbol] = struct{}{}
		quoteSymbols = append(quoteSymbols, symbol)
	}
	if len(quoteSymbols) == 0 {
		return out, nil
	}

	if ctx == nil {
		ctx = context.Background()
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, defaultQuoteTimeout)
		defer cancel()
	}

	quotes, err := qctx.Quote(ctx, quoteSymbols)
	if err != nil {
		return nil, err
	}

	for _, q := range quotes {
		if q == nil {
			continue
		}
		symbol := strings.ToUpper(strings.TrimSpace(q.Symbol))
		if _, ok := seen[symbol]; !ok {
			continue
		}
		price := currentPrice(q)
		if price == "" {
			continue
		}
		out[symbol] = price
	}
	return out, nil
}

func ensureClient() (quoteClient, error) {
	clientMu.Lock()
	defer clientMu.Unlock()
	if client != nil {
		return client, nil
	}
	c, err := newQuoteClient(cfg)
	if err != nil {
		return nil, err
	}
	client = c
	log.Info("longbridge quote client connected")
	return client, nil
}

func connectQuoteClient(c Config) (quoteClient, error) {
	sdkCfg, err := buildSDKConfig(c)
	if err != nil {
		return nil, err
	}
	qctx, err := quote.NewFromCfg(sdkCfg)
	if err != nil {
		return nil, fmt.Errorf("create longbridge quote client: %w", err)
	}
	return qctx, nil
}

func buildSDKConfig(c Config) (*lbconfig.Config, error) {
	var opts []lbconfig.Option
	if c.AppKey != "" && c.AppSecret != "" && c.AccessToken != "" {
		opts = append(opts, lbconfig.WithConfigKey(c.AppKey, c.AppSecret, c.AccessToken))
	}
	sdkCfg, err := lbconfig.New(opts...)
	if err != nil {
		return nil, fmt.Errorf("longbridge config: %w", err)
	}
	sdkCfg.EnableOvernight = true

	region := strings.TrimSpace(c.Region)
	if region == "" {
		region = os.Getenv("LONGBRIDGE_REGION")
	}
	if region == "" {
		region = os.Getenv("LONGPORT_REGION")
	}
	applyRegion(sdkCfg, region)
	return sdkCfg, nil
}

func applyRegion(cfg *lbconfig.Config, region string) {
	region = strings.ToLower(strings.TrimSpace(region))
	if region == "" {
		return
	}
	cfg.Region = lbconfig.Region(region)
	if cfg.Region != lbconfig.RegionCN {
		return
	}
	cfg.HttpURL = "https://openapi.longbridge.cn"
	cfg.QuoteUrl = "wss://openapi-quote.longbridge.cn"
	cfg.TradeUrl = "wss://openapi-trade.longbridge.cn"
}
