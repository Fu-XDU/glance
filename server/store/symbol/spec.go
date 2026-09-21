package symbol

import (
	"fmt"
	"strconv"
	"strings"
)

const (
	MarketSpot    = "spot"
	MarketFutures = "futures"
	MarketStocks  = "stocks"
)

// Spec 单个标的及其市场类型。数据源由配置块位置决定，不写在标的上。
type Spec struct {
	Symbol string
	Market string
}

func (s Spec) Normalize() Spec {
	return Spec{
		Symbol: strings.ToUpper(strings.TrimSpace(s.Symbol)),
		Market: NormalizeMarket(s.Market),
	}
}

func (s Spec) CacheKey() string {
	s = s.Normalize()
	return s.Market + ":" + s.Symbol
}

func (s Spec) TemplateKey() string {
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

// DisplayLabel 用于纯文本行情展示的标签，如 BTCUSDT、AAPL、SOLUSDT。
func (s Spec) DisplayLabel() string {
	return s.Normalize().Symbol
}

func NormalizeMarket(market string) string {
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
func ParsePriceQuery(raw string) Spec {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return Spec{}
	}

	if idx := strings.Index(raw, ":"); idx > 0 {
		market := NormalizeMarket(raw[:idx])
		symbol := strings.ToUpper(strings.TrimSpace(raw[idx+1:]))
		return Spec{Symbol: symbol, Market: market}
	}

	return Spec{Symbol: strings.ToUpper(raw), Market: MarketSpot}
}

func ResolveSpec(query string, configured []Spec) Spec {
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

// Owns 当前配置是否包含该 query 对应的标的。
func Owns(query string, configured []Spec) bool {
	spec := ResolveSpec(query, configured)
	if spec.Symbol == "" {
		return false
	}
	key := spec.CacheKey()
	for _, item := range configured {
		if item.Normalize().CacheKey() == key {
			return true
		}
	}
	return false
}

func NormalizeSpecs(specs []Spec) []Spec {
	seen := make(map[string]struct{}, len(specs))
	out := make([]Spec, 0, len(specs))
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

func TemplateKeys(specs []Spec) []string {
	out := make([]string, len(specs))
	for i, spec := range specs {
		out[i] = spec.TemplateKey()
	}
	return out
}

func FormatPrice(raw string) string {
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
