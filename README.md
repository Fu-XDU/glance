<h1 align="center">
  <br>
  <a href="https://github.com/Fu-XDU/glance"><img src="https://github.com/Fu-XDU/glance/blob/main/app/glance/Assets.xcassets/AppIcon.appiconset/ios-marketing.png?raw=true" alt="glance" width="200" style="border-radius: 22%;"></a>
  <br>
Glance
  <br>
</h1>

<h4 align="center">A minimal macOS menu bar app for at-a-glance market data.</h4>

<p align="center">
<a href="#license"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License"></a>
</p>

Glance is a lightweight macOS menu bar client backed by a small Go API server. The server reads `menu.json`, fetches Binance prices in the background, renders template placeholders, and exposes a single HTTP endpoint. The macOS app polls that endpoint and builds its status bar title and menu dynamically—no hard-coded menu structure in the client.

## Quick start

### 1. Run the API server

```bash
cd server
make start
```

The server listens on `http://127.0.0.1:1423` by default. Verify:

```bash
curl http://127.0.0.1:1423/api/menu
```

### 2. Run the macOS app

Open `app/glance.xcodeproj` in Xcode, build and run the **Glance** scheme. The app connects to `http://127.0.0.1:1423/api/menu`, shows the configured title in the menu bar, and refreshes on the interval from config.

Minimum macOS version for the app: **10.13**.

## Docker

```bash
cd server
docker compose up -d
```

Mount your own config at `./config/menu.json` (see `server/docker-compose.yaml`). The image is published as `fuming/glance:latest`.

Build locally:

```bash
cd server
make docker
```

## Menu config

Edit `server/config/menu.json`. The server hot-reads this file on every `/api/menu` request—restart is not required for menu changes.

Top-level fields:

| Field | Description |
|-------|-------------|
| `title` | Menu bar default title; supports `{{placeholders}}` |
| `refresh_after_seconds` | Hint for the macOS client poll interval (client clamps to 3–300 s) |
| `binance` | Binance REST settings and symbol list |
| `menu` | Menu tree returned to the client |

`binance` block:

| Field | Description |
|-------|-------------|
| `symbols` | Trading pairs to fetch. String (`"BTCUSDT"`) or object (`{"symbol": "SOLUSDT", "market": "futures"}`) |
| `api_key` / `api_secret` | Optional Binance API credentials |
| `base_url` | Spot API base (default `https://api.binance.com`) |
| `futures_base_url` | Futures API base (default `https://fapi.binance.com`) |
| `fetch_interval_seconds` | Server-side price refresh interval (default 10) |

Symbols are also auto-collected from `{{SYMBOL}}` placeholders in `title` and `menu` when not listed under `binance.symbols`.

## Template placeholders

Use `{{name}}` in `title`, menu `title`, and menu `value` strings.

| Placeholder | Value |
|-------------|-------|
| `{{time}}` | Current time (`15:04`) |
| `{{date}}` | Current date (`2006-01-02`) |
| `{{datetime}}` | Date and time (`2006-01-02 15:04`) |
| `{{btc_price}}` | BTC/USDT price (alias for `{{BTCUSDT}}`) |
| `{{BTCUSDT}}` | Price for the given symbol (any configured trading pair) |

For `action: "select"` items, the server also sets `status_title` to the rendered price; the macOS app uses that as the menu bar title when the symbol is selected.

## Menu actions

The macOS client recognizes these `action` values on leaf menu items:

| Action | `value` | Behavior |
|--------|---------|----------|
| `select` | Symbol id (e.g. `BTCUSDT`) | Sets menu bar title to `status_title`; choice is persisted |
| `copy` | Text | Copies `value` to the clipboard |
| `open_url` | URL string | Opens URL in the default browser |
| `quit` | — | Quits Glance |

Nested menus use a `children` array instead of `action`. If the API is unreachable, the client still shows **退出 Glance** so you can quit from the menu.

## Menu API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/menu` | Returns rendered title, refresh interval, and menu tree |

Example response (abbreviated):

```json
{
  "title": "97234.50",
  "refresh_after_seconds": 3,
  "menu": [
    {
      "title": "BTC/USDT  97234.50",
      "action": "select",
      "value": "BTCUSDT",
      "status_title": "97234.50"
    }
  ]
}
```

Custom config path at server startup:

```bash
./bin/server --menu-config /path/to/menu.json
```

## Project layout

```
glance/
├── app/                 # macOS menu bar app (Swift / AppKit)
│   └── glance.xcodeproj
└── server/              # Go API server
    ├── config/menu.json
    ├── docker-compose.yaml
    └── Makefile
```

## Development

**Server**

```bash
cd server
make dev    # go run
make test   # go test ./...
```

**macOS app**

Open `app/glance.xcodeproj` in Xcode 26+ and run the Glance target.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
