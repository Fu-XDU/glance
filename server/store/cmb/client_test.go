package cmb

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func resetState() {
	mu.Lock()
	defer mu.Unlock()
	rates = nil
}

func TestExtractCurrencyCode(t *testing.T) {
	cases := map[string]string{
		"美元 USD":  "USD",
		"港币 HKD":  "HKD",
		"日元 JPY":  "JPY",
		"USD":     "USD",
		"":        "",
		"invalid": "",
	}
	for in, want := range cases {
		if got := extractCurrencyCode(in); got != want {
			t.Fatalf("extractCurrencyCode(%q)=%q, want %q", in, got, want)
		}
	}
}

func TestParseQuery(t *testing.T) {
	code, field := parseQuery("fx:usd_bid")
	if code != "USD" || field != "bid" {
		t.Fatalf("unexpected parse: %s %s", code, field)
	}
	code, field = parseQuery("fx:EUR")
	if code != "EUR" || field != "" {
		t.Fatalf("unexpected parse default: %s %s", code, field)
	}
	if !IsQuery("fx:USD") || IsQuery("BTCUSDT") {
		t.Fatal("IsQuery mismatch")
	}
}

func TestRefreshAndRate(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"returnCode":"SUC0000",
			"errorMsg":null,
			"body":[{
				"ccyNbr":"美元",
				"ccyNbrEng":"美元 USD",
				"rtbBid":"675.47",
				"rthOfr":"677.83",
				"rtcOfr":"677.83",
				"rthBid":"673.54",
				"rtcBid":"673.54",
				"ratTim":"15:22:17",
				"ratDat":"2026年08月01日",
				"ccyExc":"100"
			}]
		}`))
	}))
	defer server.Close()

	resetState()
	Configure(Config{
		Enabled:       true,
		URL:           server.URL,
		FetchInterval: time.Hour,
	})
	refresh()

	if got := Rate("fx:USD"); got != "677.83" {
		t.Fatalf("default ask: got %q", got)
	}
	if got := Rate("fx:USD_bid"); got != "673.54" {
		t.Fatalf("bid: got %q", got)
	}
	if got := Rate("fx:USD_ask"); got != "677.83" {
		t.Fatalf("ask: got %q", got)
	}
	if got := Rate("fx:USD_mid"); got != "675.47" {
		t.Fatalf("mid: got %q", got)
	}
	if got := Rate("fx:USD_name"); got != "美元" {
		t.Fatalf("name: got %q", got)
	}
	if got := Rate("fx:EUR"); got != "--" {
		t.Fatalf("missing currency should be --, got %q", got)
	}

	lines := FormatRateLines()
	if len(lines) != 1 || lines[0] != "USD: 677.83/673.54" {
		t.Fatalf("unexpected rate lines: %#v", lines)
	}
}
