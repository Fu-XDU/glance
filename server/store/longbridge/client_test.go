package longbridge

import (
	"context"
	"testing"

	"github.com/longbridge/openapi-go/quote"
	"github.com/shopspring/decimal"
)

func TestCurrentPrice_prefersOvernight(t *testing.T) {
	last := decimal.RequireFromString("100.00")
	overnight := decimal.RequireFromString("101.50")
	q := &quote.SecurityQuote{
		Symbol:    "TSLA.US",
		LastDone:  &last,
		Timestamp: 1000,
		OverNightQuote: &quote.PrePostQuote{
			LastDone:  &overnight,
			Timestamp: 2000,
		},
	}
	if got := currentPrice(q); got != "101.5" {
		t.Fatalf("expected overnight price, got %q", got)
	}
}

func TestCurrentPrice_usesLastDoneWhenNewer(t *testing.T) {
	last := decimal.RequireFromString("250.10")
	overnight := decimal.RequireFromString("249.00")
	q := &quote.SecurityQuote{
		Symbol:    "TSLA.US",
		LastDone:  &last,
		Timestamp: 3000,
		OverNightQuote: &quote.PrePostQuote{
			LastDone:  &overnight,
			Timestamp: 1000,
		},
	}
	if got := currentPrice(q); got != "250.1" {
		t.Fatalf("expected last done price, got %q", got)
	}
}

func TestCurrentPrice_overnightOnly(t *testing.T) {
	overnight := decimal.RequireFromString("101.50")
	q := &quote.SecurityQuote{
		Symbol: "TSLA.US",
		OverNightQuote: &quote.PrePostQuote{
			LastDone:  &overnight,
			Timestamp: 2000,
		},
	}
	if got := currentPrice(q); got != "101.5" {
		t.Fatalf("expected overnight-only price, got %q", got)
	}
}

func TestCurrentPrice_ignoresEmptyOvernight(t *testing.T) {
	last := decimal.RequireFromString("180.51")
	zero := decimal.Zero
	q := &quote.SecurityQuote{
		Symbol:    "AAPL.US",
		LastDone:  &last,
		Timestamp: 1,
		OverNightQuote: &quote.PrePostQuote{
			LastDone:  &zero,
			Timestamp: 9,
		},
	}
	if got := currentPrice(q); got != "180.51" {
		t.Fatalf("expected last done, got %q", got)
	}
}

type fakeQuoteClient struct {
	symbols []string
	quotes  []*quote.SecurityQuote
	err     error
}

func (f *fakeQuoteClient) Quote(_ context.Context, symbols []string) ([]*quote.SecurityQuote, error) {
	f.symbols = append([]string(nil), symbols...)
	return f.quotes, f.err
}

func (f *fakeQuoteClient) Close() error { return nil }

func TestFetchQuotes_usesConfiguredSymbol(t *testing.T) {
	price := decimal.RequireFromString("250.10")
	fake := &fakeQuoteClient{
		quotes: []*quote.SecurityQuote{
			{Symbol: "TSLA.US", LastDone: &price, Timestamp: 1},
		},
	}
	orig := newQuoteClient
	t.Cleanup(func() {
		newQuoteClient = orig
		Configure(Config{})
	})
	Configure(Config{})
	newQuoteClient = func(Config) (quoteClient, error) { return fake, nil }

	got, err := FetchQuotes(context.Background(), []string{"TSLA.US"})
	if err != nil {
		t.Fatal(err)
	}
	if len(fake.symbols) != 1 || fake.symbols[0] != "TSLA.US" {
		t.Fatalf("expected configured symbol as-is, got %v", fake.symbols)
	}
	if got["TSLA.US"] != "250.1" {
		t.Fatalf("unexpected mapped price: %#v", got)
	}

	got, err = FetchQuotes(context.Background(), []string{"TSLA"})
	if err != nil {
		t.Fatal(err)
	}
	if len(fake.symbols) != 1 || fake.symbols[0] != "TSLA" {
		t.Fatalf("must not rewrite TSLA to TSLA.US, got %v", fake.symbols)
	}
	if _, ok := got["TSLA"]; ok {
		t.Fatalf("unmatched symbol should stay absent: %#v", got)
	}
}
