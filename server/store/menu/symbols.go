package menu

import (
	"encoding/json"
	"fmt"
	"strings"

	"glance/store/cmb"
	"glance/store/symbol"
)

func parseConfiguredSymbols(raw json.RawMessage) ([]symbol.Spec, error) {
	if len(raw) == 0 {
		return nil, nil
	}

	var entries []json.RawMessage
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil, err
	}

	out := make([]symbol.Spec, 0, len(entries))
	for _, entry := range entries {
		spec, err := parseSymbolEntry(entry)
		if err != nil {
			return nil, err
		}
		out = append(out, spec)
	}
	return out, nil
}

func parseSymbolEntry(raw json.RawMessage) (symbol.Spec, error) {
	var ticker string
	if err := json.Unmarshal(raw, &ticker); err == nil {
		return symbol.Spec{Symbol: ticker, Market: symbol.MarketSpot}, nil
	}

	var obj struct {
		Symbol string `json:"symbol"`
		Market string `json:"market"`
	}
	if err := json.Unmarshal(raw, &obj); err != nil {
		return symbol.Spec{}, err
	}
	return symbol.Spec{Symbol: obj.Symbol, Market: obj.Market}, nil
}

func collectLongBridgeSymbolSpecs(cfg *Config) ([]symbol.Spec, error) {
	if cfg.LongBridge == nil || len(cfg.LongBridge.Symbols) == 0 {
		return nil, nil
	}
	specs, err := parseConfiguredSymbols(cfg.LongBridge.Symbols)
	if err != nil {
		return nil, fmt.Errorf("parse longbridge.symbols: %w", err)
	}
	return symbol.NormalizeSpecs(specs), nil
}

func collectBinanceSymbolSpecs(cfg *Config) ([]symbol.Spec, error) {
	reserved := make(map[string]struct{})
	longbridgeSpecs, err := collectLongBridgeSymbolSpecs(cfg)
	if err != nil {
		return nil, err
	}
	for _, spec := range longbridgeSpecs {
		reserved[spec.CacheKey()] = struct{}{}
	}

	seen := make(map[string]struct{})
	out := make([]symbol.Spec, 0)
	add := func(spec symbol.Spec) {
		spec = spec.Normalize()
		if spec.Symbol == "" {
			return
		}
		key := spec.CacheKey()
		if _, ok := reserved[key]; ok {
			return
		}
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
	for _, ticker := range cfg.Symbols {
		add(symbol.Spec{Symbol: ticker, Market: symbol.MarketSpot})
	}

	var texts []string
	texts = append(texts, cfg.Title)
	collectMenuTexts(cfg.Menu, &texts)
	for _, text := range texts {
		for _, match := range templatePlaceholder.FindAllStringSubmatch(text, -1) {
			name := strings.ToLower(match[1])
			if _, reservedName := reservedPlaceholders[name]; reservedName {
				continue
			}
			query := match[1]
			if cmb.IsQuery(query) {
				continue
			}
			spec := symbol.ParsePriceQuery(query)
			if !strings.Contains(query, ":") && symbolConfigured(out, spec.Symbol) {
				continue
			}
			add(spec)
		}
	}

	return out, nil
}

func symbolConfigured(specs []symbol.Spec, ticker string) bool {
	ticker = strings.ToUpper(strings.TrimSpace(ticker))
	for _, spec := range specs {
		if spec.Normalize().Symbol == ticker {
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
