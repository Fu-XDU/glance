package binance

import (
	"encoding/json"
	"net/url"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"github.com/labstack/gommon/log"
)

const streamReadWait = 90 * time.Second

type miniTicker struct {
	Symbol string `json:"s"`
	Close  string `json:"c"`
}

// startWebSocket 现货和合约走合并 miniTicker 流；股票接口没有对应行情流，继续按 HTTP 间隔拉取。
func startWebSocket() {
	refreshPrices()

	var stocks []SymbolSpec
	byMarket := map[string][]SymbolSpec{}
	for _, spec := range cfg.Symbols {
		spec = spec.Normalize()
		if spec.Market == MarketStocks {
			stocks = append(stocks, spec)
			continue
		}
		byMarket[spec.Market] = append(byMarket[spec.Market], spec)
	}
	if specs := byMarket[MarketSpot]; len(specs) > 0 {
		go runPriceStream(streamBaseURL(cfg.BaseURL, MarketSpot), specs)
	}
	if specs := byMarket[MarketFutures]; len(specs) > 0 {
		go runPriceStream(streamBaseURL(cfg.FuturesBaseURL, MarketFutures), specs)
	}
	if len(stocks) > 0 {
		log.Info("binance stocks have no market websocket; polling those symbols over http")
		startHTTP(stocks)
	}
}

func runPriceStream(base string, specs []SymbolSpec) {
	endpoint := combinedStreamURL(base, specs)
	backoff := time.Second
	for {
		err := consumePriceStream(endpoint, specs)
		if err != nil {
			log.Errorf("binance websocket %s: %v", endpoint, err)
		}
		time.Sleep(backoff)
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

func consumePriceStream(endpoint string, specs []SymbolSpec) error {
	dialer := *websocket.DefaultDialer
	dialer.HandshakeTimeout = 10 * time.Second
	conn, _, err := dialer.Dial(endpoint, nil)
	if err != nil {
		return err
	}
	defer conn.Close()
	log.Infof("binance websocket connected: %s", endpoint)

	for {
		_ = conn.SetReadDeadline(time.Now().Add(streamReadWait))
		_, message, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		symbol, price, ok := parseMiniTicker(message)
		if !ok {
			continue
		}
		applyStreamPrice(specs, symbol, price)
	}
}

func combinedStreamURL(base string, specs []SymbolSpec) string {
	streams := make([]string, 0, len(specs))
	for _, spec := range specs {
		spec = spec.Normalize()
		if spec.Symbol == "" {
			continue
		}
		streams = append(streams, strings.ToLower(spec.Symbol)+"@miniTicker")
	}
	return strings.TrimRight(base, "/") + "/stream?streams=" + strings.Join(streams, "/")
}

func streamBaseURL(restBase, market string) string {
	host := ""
	if parsed, err := url.Parse(restBase); err == nil {
		host = strings.ToLower(parsed.Host)
	}
	if market == MarketFutures {
		switch host {
		case "testnet.binancefuture.com", "demo-fapi.binance.com":
			return "wss://stream.binancefuture.com"
		default:
			return "wss://fstream.binance.com"
		}
	}
	if host == "testnet.binance.vision" {
		return "wss://stream.testnet.binance.vision:9443"
	}
	return "wss://stream.binance.com:9443"
}

func parseMiniTicker(message []byte) (symbol, price string, ok bool) {
	var wrapped struct {
		Data miniTicker `json:"data"`
	}
	if err := json.Unmarshal(message, &wrapped); err == nil && wrapped.Data.Symbol != "" && wrapped.Data.Close != "" {
		return wrapped.Data.Symbol, wrapped.Data.Close, true
	}
	var raw miniTicker
	if err := json.Unmarshal(message, &raw); err == nil && raw.Symbol != "" && raw.Close != "" {
		return raw.Symbol, raw.Close, true
	}
	return "", "", false
}

func applyStreamPrice(specs []SymbolSpec, symbol, raw string) {
	symbol = strings.ToUpper(strings.TrimSpace(symbol))
	for _, spec := range specs {
		spec = spec.Normalize()
		if spec.Symbol == symbol {
			storeOne(spec, raw)
			return
		}
	}
}
