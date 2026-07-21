package binance

import "strings"

const (
	MarketSpot    = "spot"
	MarketFutures = "futures"
	MarketStocks  = "stocks"

	defaultFuturesBaseURL = "https://fapi.binance.com"
)

var defaultSymbolSpecs = []SymbolSpec{{Symbol: "BTCUSDT", Market: MarketSpot}}

// SymbolSpec 单个交易对及其市场类型。
type SymbolSpec struct {
	Symbol string
	Market string
}

func (s SymbolSpec) Normalize() SymbolSpec {
	return SymbolSpec{
		Symbol: strings.ToUpper(strings.TrimSpace(s.Symbol)),
		Market: normalizeMarket(s.Market),
	}
}

func (s SymbolSpec) CacheKey() string {
	s = s.Normalize()
	return s.Market + ":" + s.Symbol
}

func (s SymbolSpec) TemplateKey() string {
	s = s.Normalize()
	switch s.Market {
	case MarketFutures:
		return "futures:" + s.Symbol
	case MarketStocks:
		return "stocks:" + s.Symbol
	default:
		return s.Symbol
	}
}

func normalizeMarket(market string) string {
	switch strings.ToLower(strings.TrimSpace(market)) {
	case "futures", "future", "perp", "perpetual", "swap":
		return MarketFutures
	case "stocks", "stock", "equity", "equities":
		return MarketStocks
	default:
		return MarketSpot
	}
}

// ParsePriceQuery 解析模板或 select value，如 "futures:FOOUSDT" / "stocks:AAPL"。
func ParsePriceQuery(raw string) SymbolSpec {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return SymbolSpec{}
	}

	if idx := strings.Index(raw, ":"); idx > 0 {
		market := normalizeMarket(raw[:idx])
		symbol := strings.ToUpper(strings.TrimSpace(raw[idx+1:]))
		return SymbolSpec{Symbol: symbol, Market: market}
	}

	return SymbolSpec{Symbol: strings.ToUpper(raw), Market: MarketSpot}
}

func ResolveSpec(query string, configured []SymbolSpec) SymbolSpec {
	spec := ParsePriceQuery(query)
	if spec.Symbol == "" {
		return spec
	}
	if strings.Contains(query, ":") {
		return spec
	}
	for _, item := range configured {
		item = item.Normalize()
		if item.Symbol == spec.Symbol {
			return item
		}
	}
	return spec
}

func NormalizeSymbolSpecs(specs []SymbolSpec) []SymbolSpec {
	seen := make(map[string]struct{}, len(specs))
	out := make([]SymbolSpec, 0, len(specs))
	for _, spec := range specs {
		spec = spec.Normalize()
		if spec.Symbol == "" {
			continue
		}
		key := spec.CacheKey()
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, spec)
	}
	return out
}
