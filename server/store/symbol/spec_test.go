package symbol

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
	configured := []Spec{{Symbol: "FOOUSDT", Market: MarketFutures}}
	spec := ResolveSpec("FOOUSDT", configured)
	if spec.Market != MarketFutures {
		t.Fatalf("expected futures market, got %+v", spec)
	}

	configured = []Spec{{Symbol: "AAPL", Market: MarketStocks}}
	spec = ResolveSpec("AAPL", configured)
	if spec.Market != MarketStocks {
		t.Fatalf("expected stocks market, got %+v", spec)
	}
}

func TestOwns(t *testing.T) {
	configured := []Spec{{Symbol: "GOOG.US", Market: MarketStocks}}
	if !Owns("stocks:GOOG.US", configured) {
		t.Fatal("expected to own configured longbridge ticker")
	}
	if Owns("stocks:AAPL", configured) {
		t.Fatal("must not own a ticker from another source")
	}
	if Owns("AAPL", configured) {
		t.Fatal("bare unmatched ticker should not be owned")
	}
}

func TestSpecTemplateKey(t *testing.T) {
	if got := (Spec{Symbol: "BTCUSDT", Market: MarketSpot}).TemplateKey(); got != "BTCUSDT" {
		t.Fatalf("unexpected spot template key: %s", got)
	}
	if got := (Spec{Symbol: "FOOUSDT", Market: MarketFutures}).TemplateKey(); got != "futures:FOOUSDT" {
		t.Fatalf("unexpected futures template key: %s", got)
	}
	if got := (Spec{Symbol: "AAPL", Market: MarketStocks}).TemplateKey(); got != "stocks:AAPL" {
		t.Fatalf("unexpected stocks template key: %s", got)
	}
	if got := (Spec{Symbol: "AAPL", Market: MarketStocks}).DisplayLabel(); got != "AAPL" {
		t.Fatalf("unexpected stocks display label: %s", got)
	}
	if got := (Spec{Symbol: "SOLUSDT", Market: MarketFutures}).DisplayLabel(); got != "SOLUSDT" {
		t.Fatalf("unexpected futures display label: %s", got)
	}
}

func TestFormatPrice(t *testing.T) {
	if got := FormatPrice("98765.43000000"); got != "98765.43" {
		t.Fatalf("unexpected formatted price: %s", got)
	}
	if got := FormatPrice("0.12345"); got != "0.1235" {
		t.Fatalf("unexpected small price: %s", got)
	}
}
