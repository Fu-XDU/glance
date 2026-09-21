package binance

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func resetState() {
	mu.Lock()
	defer mu.Unlock()
	displayPrice = nil
	lastUpdated = time.Time{}
}

func TestRefreshPrices_singleSymbol(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v3/ticker/price" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		if r.URL.Query().Get("symbol") != "BTCUSDT" {
			t.Fatalf("unexpected symbol: %s", r.URL.Query().Get("symbol"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"symbol":"BTCUSDT","price":"98765.43000000"}`))
	}))
	defer server.Close()

	resetState()
	Configure(Config{
		BaseURL: server.URL,
		Symbols: []SymbolSpec{{Symbol: "BTCUSDT", Market: MarketSpot}},
	})
	refreshPrices()

	if got := Price("BTCUSDT"); got != "98765.43" {
		t.Fatalf("unexpected formatted price: %s", got)
	}
}

func TestRefreshPrices_futuresSymbol(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/fapi/v1/ticker/price" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		if r.URL.Query().Get("symbol") != "FOOUSDT" {
			t.Fatalf("unexpected symbol: %s", r.URL.Query().Get("symbol"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"symbol":"FOOUSDT","price":"1.23450000"}`))
	}))
	defer server.Close()

	resetState()
	Configure(Config{
		FuturesBaseURL: server.URL,
		Symbols:        []SymbolSpec{{Symbol: "FOOUSDT", Market: MarketFutures}},
	})
	refreshPrices()

	if got := Price("futures:FOOUSDT"); got != "1.23" {
		t.Fatalf("unexpected futures price: %s", got)
	}
}

func TestRefreshPrices_stocksSymbol(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/sapi/v1/equity/market/quote" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		if r.Header.Get("X-MBX-APIKEY") != "test-key" {
			t.Fatalf("expected API key header, got %q", r.Header.Get("X-MBX-APIKEY"))
		}
		if r.URL.Query().Get("symbol") != "AAPL" {
			t.Fatalf("unexpected symbol: %s", r.URL.Query().Get("symbol"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"symbol":"AAPL","bidPrice":"180.50","askPrice":"180.52","bidSize":100,"askSize":200}`))
	}))
	defer server.Close()

	resetState()
	Configure(Config{
		BaseURL: server.URL,
		APIKey:  "test-key",
		Symbols: []SymbolSpec{{Symbol: "AAPL", Market: MarketStocks}},
	})
	refreshPrices()

	if got := Price("stocks:AAPL"); got != "180.51" {
		t.Fatalf("unexpected stocks mid price: %s", got)
	}
	if got := Price("AAPL"); got != "180.51" {
		t.Fatalf("expected configured stocks market for bare ticker, got %s", got)
	}
}

func TestRefreshPrices_stocksEmptyQuote(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	resetState()
	Configure(Config{
		BaseURL: server.URL,
		APIKey:  "test-key",
		Symbols: []SymbolSpec{{Symbol: "ZZZZ", Market: MarketStocks}},
	})
	refreshPrices()

	if got := Price("stocks:ZZZZ"); got != "--" {
		t.Fatalf("expected placeholder for empty quote, got %q", got)
	}
}

func TestRefreshPrices_multipleSymbols(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.URL.RawQuery, "symbols=") {
			t.Fatalf("expected batch symbols query: %s", r.URL.RawQuery)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[
			{"symbol":"BTCUSDT","price":"50000.00000000"},
			{"symbol":"ETHUSDT","price":"3000.12000000"}
		]`))
	}))
	defer server.Close()

	resetState()
	Configure(Config{
		BaseURL: server.URL,
		Symbols: []SymbolSpec{
			{Symbol: "BTCUSDT", Market: MarketSpot},
			{Symbol: "ETHUSDT", Market: MarketSpot},
		},
	})
	refreshPrices()

	if got := Price("BTCUSDT"); got != "50000.00" {
		t.Fatalf("unexpected btc price: %s", got)
	}
	if got := Price("ETHUSDT"); got != "3000.12" {
		t.Fatalf("unexpected eth price: %s", got)
	}
}

func TestRefreshPrices_batchFailureFallback(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.RawQuery, "symbols=") {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"code":-1121,"msg":"Invalid symbol."}`))
			return
		}
		switch r.URL.Query().Get("symbol") {
		case "BTCUSDT":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"symbol":"BTCUSDT","price":"50000.00000000"}`))
		default:
			w.WriteHeader(http.StatusBadRequest)
		}
	}))
	defer server.Close()

	resetState()
	Configure(Config{
		BaseURL: server.URL,
		Symbols: []SymbolSpec{
			{Symbol: "BTCUSDT", Market: MarketSpot},
			{Symbol: "INVALIDUSDT", Market: MarketSpot},
		},
	})
	refreshPrices()

	if got := Price("BTCUSDT"); got != "50000.00" {
		t.Fatalf("expected btc price from fallback fetch, got %q", got)
	}
	if got := Price("INVALIDUSDT"); got != "--" {
		t.Fatalf("expected invalid symbol placeholder, got %q", got)
	}
}

func TestPrice_beforeFetch(t *testing.T) {
	resetState()
	Configure(Config{Symbols: []SymbolSpec{{Symbol: "BTCUSDT", Market: MarketSpot}}})
	if got := Price("BTCUSDT"); got != "--" {
		t.Fatalf("expected placeholder before fetch, got %q", got)
	}
}
