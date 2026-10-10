package binance

import "testing"

func TestParseMiniTicker_combinedAndRaw(t *testing.T) {
	symbol, price, ok := parseMiniTicker([]byte(`{"stream":"btcusdt@miniTicker","data":{"e":"24hrMiniTicker","s":"BTCUSDT","c":"100.5"}}`))
	if !ok || symbol != "BTCUSDT" || price != "100.5" {
		t.Fatalf("combined = %s %s %v", symbol, price, ok)
	}
	symbol, price, ok = parseMiniTicker([]byte(`{"e":"24hrMiniTicker","s":"ETHUSDT","c":"8.25"}`))
	if !ok || symbol != "ETHUSDT" || price != "8.25" {
		t.Fatalf("raw = %s %s %v", symbol, price, ok)
	}
	if _, _, ok = parseMiniTicker([]byte(`{"data":{}}`)); ok {
		t.Fatal("expected empty payload to be ignored")
	}
}

func TestStreamBaseURL(t *testing.T) {
	if got := streamBaseURL("https://api.binance.com", MarketSpot); got != "wss://stream.binance.com:9443" {
		t.Fatalf("spot = %s", got)
	}
	if got := streamBaseURL("https://fapi.binance.com", MarketFutures); got != "wss://fstream.binance.com" {
		t.Fatalf("futures = %s", got)
	}
	if got := streamBaseURL("https://testnet.binance.vision", MarketSpot); got != "wss://stream.testnet.binance.vision:9443" {
		t.Fatalf("spot testnet = %s", got)
	}
}

func TestCombinedStreamURL(t *testing.T) {
	got := combinedStreamURL("wss://stream.binance.com:9443", []SymbolSpec{
		{Symbol: "BTCUSDT", Market: MarketSpot},
		{Symbol: "ethusdt", Market: MarketSpot},
	})
	want := "wss://stream.binance.com:9443/stream?streams=btcusdt@miniTicker/ethusdt@miniTicker"
	if got != want {
		t.Fatalf("got %s", got)
	}
}

func TestApplyStreamPrice_updatesCache(t *testing.T) {
	resetState()
	Configure(Config{Symbols: []SymbolSpec{{Symbol: "BTCUSDT", Market: MarketSpot}}})
	applyStreamPrice(cfg.Symbols, "btcusdt", "42000.5")
	if got := Price("BTCUSDT"); got != "42000.50" {
		t.Fatalf("price = %s", got)
	}
}
