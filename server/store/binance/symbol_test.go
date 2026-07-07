package binance

import "testing"

func TestParsePriceQuery(t *testing.T) {
	spec := ParsePriceQuery("futures:fooUSDT")
	if spec.Market != MarketFutures || spec.Symbol != "FOOUSDT" {
		t.Fatalf("unexpected futures spec: %+v", spec)
	}

	spec = ParsePriceQuery("BTCUSDT")
	if spec.Market != MarketSpot || spec.Symbol != "BTCUSDT" {
		t.Fatalf("unexpected spot spec: %+v", spec)
	}
}

func TestResolveSpec_prefersConfiguredMarket(t *testing.T) {
	configured := []SymbolSpec{{Symbol: "FOOUSDT", Market: MarketFutures}}
	spec := ResolveSpec("FOOUSDT", configured)
	if spec.Market != MarketFutures {
		t.Fatalf("expected futures market, got %+v", spec)
	}
}

func TestSymbolSpecTemplateKey(t *testing.T) {
	if got := (SymbolSpec{Symbol: "BTCUSDT", Market: MarketSpot}).TemplateKey(); got != "BTCUSDT" {
		t.Fatalf("unexpected spot template key: %s", got)
	}
	if got := (SymbolSpec{Symbol: "FOOUSDT", Market: MarketFutures}).TemplateKey(); got != "futures:FOOUSDT" {
		t.Fatalf("unexpected futures template key: %s", got)
	}
}
