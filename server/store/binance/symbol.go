package binance

import "glance/store/symbol"

const (
	MarketSpot    = symbol.MarketSpot
	MarketFutures = symbol.MarketFutures
	MarketStocks  = symbol.MarketStocks

	defaultFuturesBaseURL = "https://fapi.binance.com"
)

type SymbolSpec = symbol.Spec

var defaultSymbolSpecs = []SymbolSpec{{Symbol: "BTCUSDT", Market: MarketSpot}}

func ParsePriceQuery(raw string) SymbolSpec {
	return symbol.ParsePriceQuery(raw)
}

func ResolveSpec(query string, configured []SymbolSpec) SymbolSpec {
	return symbol.ResolveSpec(query, configured)
}

func NormalizeSymbolSpecs(specs []SymbolSpec) []SymbolSpec {
	return symbol.NormalizeSpecs(specs)
}
