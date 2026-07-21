package menu

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"glance/store/binance"
)

func TestLoadResponse_rendersTemplates(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "menu.json")
	data := `{
  "title": "Clock {{time}}",
  "refresh_after_seconds": 15,
  "menu": [
    {
      "title": "Copy date",
      "action": "copy",
      "value": "{{date}}"
    }
  ]
}`
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}

	configPath = path
	resp, err := LoadResponse()
	if err != nil {
		t.Fatal(err)
	}
	if resp.Title == "Clock {{time}}" {
		t.Fatalf("title template not rendered: %q", resp.Title)
	}
	if resp.RefreshAfterSeconds == nil || *resp.RefreshAfterSeconds != 15 {
		t.Fatalf("unexpected refresh interval: %+v", resp.RefreshAfterSeconds)
	}
	if len(resp.Menu) != 1 || resp.Menu[0].Value == nil || *resp.Menu[0].Value == "{{date}}" {
		t.Fatalf("menu value template not rendered: %+v", resp.Menu)
	}
}

func TestLoadResponse_defaultTitle(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "menu.json")
	data := `{"menu": []}`
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}

	configPath = path
	resp, err := LoadResponse()
	if err != nil {
		t.Fatal(err)
	}
	if resp.Title != "Glance" {
		t.Fatalf("expected default title Glance, got %q", resp.Title)
	}
}

func TestLoadBinanceConfig_collectsSymbolsFromMenu(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "menu.json")
	data := `{
  "title": "{{DOGEUSDT}}",
  "menu": [
    {"title": "BNB {{BNBUSDT}}", "action": "select", "value": "BNBUSDT"}
  ]
}`
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}

	configPath = path
	cfg, err := LoadBinanceConfig()
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Symbols) != 2 || cfg.Symbols[0].Symbol != "DOGEUSDT" || cfg.Symbols[1].Symbol != "BNBUSDT" {
		t.Fatalf("unexpected collected symbols: %#v", cfg.Symbols)
	}
}

func TestLoadBinanceConfig_futuresSymbol(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "menu.json")
	data := `{
  "binance": {
    "symbols": [
      {"symbol": "FOOUSDT", "market": "futures"}
    ]
  },
  "menu": [
    {"title": "FOO {{FOOUSDT}}", "action": "select", "value": "FOOUSDT"}
  ]
}`
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}

	configPath = path
	cfg, err := LoadBinanceConfig()
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Symbols) != 1 || cfg.Symbols[0].Market != binance.MarketFutures || cfg.Symbols[0].Symbol != "FOOUSDT" {
		t.Fatalf("unexpected futures symbol config: %#v", cfg.Symbols)
	}
}

func TestLoadBinanceConfig_stocksSymbol(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "menu.json")
	data := `{
  "binance": {
    "symbols": [
      {"symbol": "AAPL", "market": "stocks"}
    ],
    "api_key": "key-1"
  },
  "menu": [
    {"title": "AAPL {{stocks:AAPL}}", "action": "select", "value": "stocks:AAPL"}
  ]
}`
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}

	configPath = path
	cfg, err := LoadBinanceConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.APIKey != "key-1" {
		t.Fatalf("expected api key, got %q", cfg.APIKey)
	}
	if len(cfg.Symbols) != 1 || cfg.Symbols[0].Market != binance.MarketStocks || cfg.Symbols[0].Symbol != "AAPL" {
		t.Fatalf("unexpected stocks symbol config: %#v", cfg.Symbols)
	}
}

func TestLoadResponse_selectItemStatusTitle(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "menu.json")
	data := `{
  "menu": [
    {
      "title": "ETH/USDT {{ETHUSDT}}",
      "action": "select",
      "value": "ETHUSDT"
    }
  ]
}`
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}

	configPath = path
	resp, err := LoadResponse()
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.Menu) != 1 || resp.Menu[0].StatusTitle == nil {
		t.Fatalf("expected status_title on select item: %+v", resp.Menu[0])
	}
	if *resp.Menu[0].StatusTitle == "" || strings.Contains(*resp.Menu[0].StatusTitle, "{{") {
		t.Fatalf("expected rendered status_title, got %q", *resp.Menu[0].StatusTitle)
	}
	if !strings.Contains(resp.Menu[0].Title, "/") {
		t.Fatalf("menu title should still include symbol label: %q", resp.Menu[0].Title)
	}
}

func TestLoadBinanceConfig_fromBinanceBlock(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "menu.json")
	data := `{
  "binance": {
    "symbols": ["btcusdt", "ETHUSDT"],
    "api_key": "key-1",
    "api_secret": "secret-1",
    "base_url": "https://example.com",
    "fetch_interval_seconds": 15
  },
  "menu": []
}`
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}

	configPath = path
	cfg, err := LoadBinanceConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.APIKey != "key-1" || cfg.APISecret != "secret-1" || cfg.BaseURL != "https://example.com" {
		t.Fatalf("unexpected binance credentials/base url: %+v", cfg)
	}
	if cfg.FetchInterval != 15*time.Second {
		t.Fatalf("unexpected fetch interval: %v", cfg.FetchInterval)
	}
	if len(cfg.Symbols) != 2 || cfg.Symbols[0].Symbol != "BTCUSDT" || cfg.Symbols[1].Symbol != "ETHUSDT" {
		t.Fatalf("unexpected symbols: %#v", cfg.Symbols)
	}
}
