package longbridge

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/labstack/gommon/log"
	lbconfig "github.com/longbridge/openapi-go/config"
	"github.com/longbridge/openapi-go/quote"
)

const defaultQuoteTimeout = 8 * time.Second

// Config LongBridge 行情凭证。空字段回退到环境变量。
type Config struct {
	AppKey      string
	AppSecret   string
	AccessToken string
	Region      string
}

type quoteClient interface {
	Quote(ctx context.Context, symbols []string) ([]*quote.SecurityQuote, error)
	Close() error
}

var (
	cfg Config

	clientMu sync.Mutex
	client   quoteClient

	newQuoteClient = connectQuoteClient
)

// Configure 保存 LongBridge 凭证（进程启动时调用一次）。
func Configure(c Config) {
	clientMu.Lock()
	defer clientMu.Unlock()
	if client != nil {
		_ = client.Close()
		client = nil
	}
	cfg = c
}

// FetchQuotes 按配置中的 symbol 原样向 LongBridge 询价，不做后缀改写。
func FetchQuotes(ctx context.Context, symbols []string) (map[string]string, error) {
	out := make(map[string]string, len(symbols))
	if len(symbols) == 0 {
		return out, nil
	}

	qctx, err := ensureClient()
	if err != nil {
		return nil, err
	}

	quoteSymbols := make([]string, 0, len(symbols))
	seen := make(map[string]struct{}, len(symbols))
	for _, symbol := range symbols {
		symbol = strings.ToUpper(strings.TrimSpace(symbol))
		if symbol == "" {
			continue
		}
		if _, ok := seen[symbol]; ok {
			continue
		}
		seen[symbol] = struct{}{}
		quoteSymbols = append(quoteSymbols, symbol)
	}
	if len(quoteSymbols) == 0 {
		return out, nil
	}

	if ctx == nil {
		ctx = context.Background()
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, defaultQuoteTimeout)
		defer cancel()
	}

	quotes, err := qctx.Quote(ctx, quoteSymbols)
	if err != nil {
		return nil, err
	}

	for _, q := range quotes {
		if q == nil {
			continue
		}
		symbol := strings.ToUpper(strings.TrimSpace(q.Symbol))
		if _, ok := seen[symbol]; !ok {
			continue
		}
		price := currentPrice(q)
		if price == "" {
			continue
		}
		out[symbol] = price
	}
	return out, nil
}

func ensureClient() (quoteClient, error) {
	clientMu.Lock()
	defer clientMu.Unlock()
	if client != nil {
		return client, nil
	}
	c, err := newQuoteClient(cfg)
	if err != nil {
		return nil, err
	}
	client = c
	log.Info("longbridge quote client connected")
	return client, nil
}

func connectQuoteClient(c Config) (quoteClient, error) {
	sdkCfg, err := buildSDKConfig(c)
	if err != nil {
		return nil, err
	}
	qctx, err := quote.NewFromCfg(sdkCfg)
	if err != nil {
		return nil, fmt.Errorf("create longbridge quote client: %w", err)
	}
	return qctx, nil
}

func buildSDKConfig(c Config) (*lbconfig.Config, error) {
	var opts []lbconfig.Option
	if c.AppKey != "" && c.AppSecret != "" && c.AccessToken != "" {
		opts = append(opts, lbconfig.WithConfigKey(c.AppKey, c.AppSecret, c.AccessToken))
	}
	sdkCfg, err := lbconfig.New(opts...)
	if err != nil {
		return nil, fmt.Errorf("longbridge config: %w", err)
	}
	sdkCfg.EnableOvernight = true

	region := strings.TrimSpace(c.Region)
	if region == "" {
		region = os.Getenv("LONGBRIDGE_REGION")
	}
	if region == "" {
		region = os.Getenv("LONGPORT_REGION")
	}
	applyRegion(sdkCfg, region)
	return sdkCfg, nil
}

func applyRegion(cfg *lbconfig.Config, region string) {
	region = strings.ToLower(strings.TrimSpace(region))
	if region == "" {
		return
	}
	cfg.Region = lbconfig.Region(region)
	if cfg.Region != lbconfig.RegionCN {
		return
	}
	cfg.HttpURL = "https://openapi.longbridge.cn"
	cfg.QuoteUrl = "wss://openapi-quote.longbridge.cn"
	cfg.TradeUrl = "wss://openapi-trade.longbridge.cn"
}
