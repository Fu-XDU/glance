package menu

import (
	"fmt"
	"strings"

	"glance/store/binance"
	"glance/store/cmb"
)

// FormatPricesText 返回人类可读的纯文本行情快照。
func FormatPricesText() string {
	var b strings.Builder
	for _, spec := range binance.SymbolSpecs() {
		spec = spec.Normalize()
		fmt.Fprintf(&b, "%s: %s\n", spec.DisplayLabel(), binance.Price(spec.TemplateKey()))
	}
	for _, line := range cmb.FormatRateLines() {
		b.WriteString(line)
		b.WriteByte('\n')
	}
	return b.String()
}
