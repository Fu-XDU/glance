package binance

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/labstack/gommon/log"
)

const (
	defaultBaseURL       = "https://api.binance.com"
	defaultFetchInterval = 10 * time.Second
)

// Config Binance REST 客户端配置。
type Config struct {
	BaseURL        string
	FuturesBaseURL string
	APIKey         string
	APISecret      string
	Symbols        []SymbolSpec
	FetchInterval  time.Duration
}

var (
	cfg Config

	mu           sync.RWMutex
	displayPrice map[string]string
	lastUpdated  time.Time

	httpClient = &http.Client{Timeout: 5 * time.Second}
)

// Configure 设置 Binance 客户端（进程启动时调用一次）。
func Configure(c Config) {
	if c.BaseURL == "" {
		c.BaseURL = defaultBaseURL
	}
	if c.FuturesBaseURL == "" {
		c.FuturesBaseURL = defaultFuturesBaseURL
	}
	if c.FetchInterval <= 0 {
		c.FetchInterval = defaultFetchInterval
	}
	if len(c.Symbols) == 0 {
		c.Symbols = append([]SymbolSpec(nil), defaultSymbolSpecs...)
	} else {
		c.Symbols = NormalizeSymbolSpecs(c.Symbols)
	}
	cfg = c

	mu.Lock()
	displayPrice = make(map[string]string, len(cfg.Symbols))
	mu.Unlock()

	for _, spec := range cfg.Symbols {
		spec = spec.Normalize()
		log.Infof("binance symbol configured: %s (%s)", spec.Symbol, spec.Market)
	}
}

// SymbolSpecs 返回当前配置的交易对列表。
func SymbolSpecs() []SymbolSpec {
	out := make([]SymbolSpec, len(cfg.Symbols))
	copy(out, cfg.Symbols)
	return out
}

// Symbols 返回模板占位符列表。
func Symbols() []string {
	specs := SymbolSpecs()
	out := make([]string, len(specs))
	for i, spec := range specs {
		out[i] = spec.TemplateKey()
	}
	return out
}

// Start 启动后台定时拉取，并在启动时立即拉取一次。
func Start() {
	refreshPrices()
	go func() {
		ticker := time.NewTicker(cfg.FetchInterval)
		defer ticker.Stop()
		for range ticker.C {
			refreshPrices()
		}
	}()
}

type tickerPriceResponse struct {
	Symbol string `json:"symbol"`
	Price  string `json:"price"`
}

// Price 返回内存中的格式化价格；query 可为 "BTCUSDT" 或 "futures:FOOUSDT"。
func Price(query string) string {
	spec := ResolveSpec(query, cfg.Symbols)
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

// BTCUSDTPrice 兼容旧模板 {{btc_price}}。
func BTCUSDTPrice() string {
	return Price("BTCUSDT")
}

func refreshPrices() {
	rawPrices := fetchAllPrices(cfg.Symbols)

	mu.Lock()
	defer mu.Unlock()

	lastUpdated = time.Now()
	for _, spec := range cfg.Symbols {
		key := spec.CacheKey()
		raw, ok := rawPrices[key]
		if !ok || raw == "" {
			if displayPrice[key] == "" {
				displayPrice[key] = "--"
			}
			continue
		}
		displayPrice[key] = formatPrice(raw)
        log.Infof("%v: %v", key, displayPrice[key])
	}
}

func fetchAllPrices(specs []SymbolSpec) map[string]string {
	out := make(map[string]string, len(specs))
	if len(specs) == 0 {
		return out
	}

	var (
		wg sync.WaitGroup
		mu sync.Mutex
	)

	byMarket := map[string][]SymbolSpec{
		MarketSpot:    {},
		MarketFutures: {},
	}
	for _, spec := range specs {
		spec = spec.Normalize()
		byMarket[spec.Market] = append(byMarket[spec.Market], spec)
	}

	fetchMarket := func(market string, marketSpecs []SymbolSpec) {
		defer wg.Done()
		marketPrices := fetchMarketPrices(market, marketSpecs)
		mu.Lock()
		for key, price := range marketPrices {
			out[key] = price
		}
		mu.Unlock()
	}

	for market, marketSpecs := range byMarket {
		if len(marketSpecs) == 0 {
			continue
		}
		wg.Add(1)
		go fetchMarket(market, marketSpecs)
	}

	wg.Wait()
	return out
}

func fetchMarketPrices(market string, marketSpecs []SymbolSpec) map[string]string {
	out := make(map[string]string, len(marketSpecs))
	symbols := make([]string, len(marketSpecs))
	for i, spec := range marketSpecs {
		symbols[i] = spec.Symbol
	}

	if len(symbols) > 1 {
		if batch, err := requestPrices(market, symbols); err == nil {
			for _, spec := range marketSpecs {
				if price, ok := batch[spec.Symbol]; ok {
					out[spec.CacheKey()] = price
				}
			}
		} else {
			log.Warnf("binance %s batch price fetch failed, fallback to per-symbol requests: %v", market, err)
		}
	}

	var wg sync.WaitGroup
	var mu sync.Mutex
	for _, spec := range marketSpecs {
		key := spec.CacheKey()
		if out[key] != "" {
			continue
		}
		wg.Add(1)
		go func(spec SymbolSpec) {
			defer wg.Done()
			priceMap, err := requestPrices(market, []string{spec.Symbol})
			if err != nil {
				log.Errorf("binance %s price fetch failed for %s: %v", market, spec.Symbol, err)
				return
			}
			mu.Lock()
			out[spec.CacheKey()] = priceMap[spec.Symbol]
			mu.Unlock()
		}(spec)
	}
	wg.Wait()
	return out
}

func requestPrices(market string, symbols []string) (map[string]string, error) {
	if len(symbols) == 0 {
		return nil, fmt.Errorf("no symbols configured")
	}

	baseURL := cfg.BaseURL
	pricePath := "/api/v3/ticker/price"
	if market == MarketFutures {
		baseURL = cfg.FuturesBaseURL
		pricePath = "/fapi/v1/ticker/price"
	}

	endpoint := strings.TrimRight(baseURL, "/") + pricePath
	query := url.Values{}
	if len(symbols) == 1 {
		query.Set("symbol", symbols[0])
		// log.Infof("binance requesting %s %s price: %s?%s", market, symbols[0], endpoint, query.Encode())
	} else {
		encoded, err := json.Marshal(symbols)
		if err != nil {
			return nil, err
		}
		query.Set("symbols", string(encoded))
		// log.Infof("binance requesting %s batch prices: %s?%s", market, endpoint, query.Encode())
	}

	req, err := http.NewRequest(http.MethodGet, endpoint+"?"+query.Encode(), nil)
	if err != nil {
		return nil, err
	}
	if cfg.APIKey != "" {
		req.Header.Set("X-MBX-APIKEY", cfg.APIKey)
	}

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
		return nil, fmt.Errorf("binance api status %d: %s", resp.StatusCode, string(body))
	}

	return parsePriceResponse(body, len(symbols) == 1)
}

func parsePriceResponse(body []byte, single bool) (map[string]string, error) {
	out := make(map[string]string)
	if single {
		var data tickerPriceResponse
		if err := json.Unmarshal(body, &data); err != nil {
			return nil, err
		}
		if data.Symbol == "" || data.Price == "" {
			return nil, fmt.Errorf("invalid binance response: %s", string(body))
		}
		out[data.Symbol] = data.Price
		return out, nil
	}

	var list []tickerPriceResponse
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, err
	}
	for _, item := range list {
		if item.Symbol == "" || item.Price == "" {
			continue
		}
		out[item.Symbol] = item.Price
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("empty binance response: %s", string(body))
	}
	return out, nil
}

func formatPrice(raw string) string {
	value, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return raw
	}
	switch {
	case value >= 1:
		return fmt.Sprintf("%.2f", value)
	default:
		return fmt.Sprintf("%.4f", value)
	}
}
