package longbridge

import "github.com/longbridge/openapi-go/quote"

// currentPrice 取最新成交价，含夜盘；不区分盘前/盘后/夜盘会话。
func currentPrice(q *quote.SecurityQuote) string {
	if q == nil {
		return ""
	}

	price, ts := "", int64(0)
	if q.LastDone != nil && !q.LastDone.IsZero() {
		price = q.LastDone.String()
		ts = q.Timestamp
	}

	try := func(p *quote.PrePostQuote) {
		if p == nil || p.LastDone == nil || p.LastDone.IsZero() {
			return
		}
		if p.Timestamp >= ts {
			price = p.LastDone.String()
			ts = p.Timestamp
		}
	}
	try(q.PreMarketQuote)
	try(q.PostMarketQuote)
	try(q.OverNightQuote)
	return price
}
