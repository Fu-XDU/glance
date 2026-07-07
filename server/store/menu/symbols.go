package menu

import (
	"encoding/json"
	"fmt"
	"strings"

	"glance/store/binance"
)

func parseConfiguredSymbols(raw json.RawMessage) ([]binance.SymbolSpec, error) {
	if len(raw) == 0 {
		return nil, nil
	}

	var entries []json.RawMessage
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil, err
	}

	out := make([]binance.SymbolSpec, 0, len(entries))
	for _, entry := range entries {
		spec, err := parseSymbolEntry(entry)
		if err != nil {
			return nil, err
		}
		out = append(out, spec)
	}
	return out, nil
}

func parseSymbolEntry(raw json.RawMessage) (binance.SymbolSpec, error) {
	var symbol string
	if err := json.Unmarshal(raw, &symbol); err == nil {
		return binance.SymbolSpec{Symbol: symbol, Market: binance.MarketSpot}, nil
	}

	var obj struct {
		Symbol string `json:"symbol"`
		Market string `json:"market"`
	}
	if err := json.Unmarshal(raw, &obj); err != nil {
		return binance.SymbolSpec{}, err
	}
	return binance.SymbolSpec{Symbol: obj.Symbol, Market: obj.Market}, nil
}

func collectSymbolSpecs(cfg *Config) ([]binance.SymbolSpec, error) {
	seen := make(map[string]struct{})
	out := make([]binance.SymbolSpec, 0)

	add := func(spec binance.SymbolSpec) {
		spec = spec.Normalize()
		if spec.Symbol == "" {
			return
		}
		key := spec.CacheKey()
		if _, ok := seen[key]; ok {
			return
		}
		seen[key] = struct{}{}
		out = append(out, spec)
	}

	if cfg.Binance != nil && len(cfg.Binance.Symbols) > 0 {
		configured, err := parseConfiguredSymbols(cfg.Binance.Symbols)
		if err != nil {
			return nil, fmt.Errorf("parse binance.symbols: %w", err)
		}
		for _, spec := range configured {
			add(spec)
		}
	}
	for _, symbol := range cfg.Symbols {
		add(binance.SymbolSpec{Symbol: symbol, Market: binance.MarketSpot})
	}

	var texts []string
	texts = append(texts, cfg.Title)
	collectMenuTexts(cfg.Menu, &texts)
	for _, text := range texts {
		for _, match := range templatePlaceholder.FindAllStringSubmatch(text, -1) {
			name := strings.ToLower(match[1])
			if _, reserved := reservedPlaceholders[name]; reserved {
				continue
			}
			query := match[1]
			spec := binance.ParsePriceQuery(query)
			if !strings.Contains(query, ":") && symbolConfigured(out, spec.Symbol) {
				continue
			}
			add(spec)
		}
	}

	return out, nil
}

func symbolConfigured(specs []binance.SymbolSpec, symbol string) bool {
	symbol = strings.ToUpper(strings.TrimSpace(symbol))
	for _, spec := range specs {
		if spec.Normalize().Symbol == symbol {
			return true
		}
	}
	return false
}

func collectMenuTexts(items []Item, texts *[]string) {
	for _, item := range items {
		*texts = append(*texts, item.Title)
		if item.Action != nil {
			*texts = append(*texts, *item.Action)
		}
		if item.Value != nil {
			*texts = append(*texts, *item.Value)
		}
		if len(item.Children) > 0 {
			collectMenuTexts(item.Children, texts)
		}
	}
}
