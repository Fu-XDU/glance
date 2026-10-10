package controller

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"glance/store/menu"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

func TestMenuWebSocket_sendsMenuSnapshot(t *testing.T) {
	gin.SetMode(gin.TestMode)
	dir := t.TempDir()
	path := filepath.Join(dir, "menu.json")
	body := `{
  "title": "WS Glance",
  "refresh_after_seconds": 3,
  "menu": [
    {"title": "BTC", "action": "select", "value": "BTCUSDT"}
  ]
}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	menu.SetConfigPath(path)

	router := gin.New()
	router.GET("/api/menu", GetMenu)
	server := httptest.NewServer(router)
	t.Cleanup(server.Close)

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/api/menu"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, data, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var resp menu.Response
	if err := json.Unmarshal(data, &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Title != "WS Glance" {
		t.Fatalf("title = %q", resp.Title)
	}
	if len(resp.Menu) != 1 || resp.Menu[0].Title != "BTC" {
		t.Fatalf("menu = %+v", resp.Menu)
	}
}
