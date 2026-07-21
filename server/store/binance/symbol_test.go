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

	spec = ParsePriceQuery("stocks:aapl")
	if spec.Market != MarketStocks || spec.Symbol != "AAPL" {
		t.Fatalf("unexpected stocks spec: %+v", spec)
	}
}

func TestResolveSpec_prefersConfiguredMarket(t *testing.T) {
	configured := []SymbolSpec{{Symbol: "FOOUSDT", Market: MarketFutures}}
	spec := ResolveSpec("FOOUSDT", configured)
	if spec.Market != MarketFutures {
		t.Fatalf("expected futures market, got %+v", spec)
	}

	configured = []SymbolSpec{{Symbol: "AAPL", Market: MarketStocks}}
	spec = ResolveSpec("AAPL", configured)
	if spec.Market != MarketStocks {
		t.Fatalf("expected stocks market, got %+v", spec)
	}
}

func TestSymbolSpecTemplateKey(t *testing.T) {
	if got := (SymbolSpec{Symbol: "BTCUSDT", Market: MarketSpot}).TemplateKey(); got != "BTCUSDT" {
		t.Fatalf("unexpected spot template key: %s", got)
	}
	if got := (SymbolSpec{Symbol: "FOOUSDT", Market: MarketFutures}).TemplateKey(); got != "futures:FOOUSDT" {
		t.Fatalf("unexpected futures template key: %s", got)
	}
	if got := (SymbolSpec{Symbol: "AAPL", Market: MarketStocks}).TemplateKey(); got != "stocks:AAPL" {
		t.Fatalf("unexpected stocks template key: %s", got)
	}
}

func TestMidQuotePrice(t *testing.T) {
	if got := midQuotePrice("180.50", "180.52"); got != "180.51" {
		t.Fatalf("unexpected mid quote: %s", got)
	}
	if got := midQuotePrice("", "180.52"); got != "180.52" {
		t.Fatalf("expected ask fallback, got %s", got)
	}
	if got := midQuotePrice("180.50", ""); got != "180.50" {
		t.Fatalf("expected bid fallback, got %s", got)
	}
}
