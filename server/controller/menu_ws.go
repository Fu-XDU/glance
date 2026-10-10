package controller

import (
	"bytes"
	"net/http"
	"sync"
	"time"

	"glance/store/menu"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

const (
	menuPushInterval = time.Second
	menuWriteWait    = 5 * time.Second
	menuPongWait     = 60 * time.Second
	menuPingPeriod   = 30 * time.Second
)

var (
	menuUpgrader = websocket.Upgrader{
		CheckOrigin: func(*http.Request) bool { return true },
	}
	menuSockets = newMenuHub()
)

func init() {
	go broadcastMenu()
}

// serveMenuWebSocket 把 GET /api/menu 升级为 WebSocket，推送与 HTTP 相同的菜单 JSON。
func serveMenuWebSocket(c *gin.Context) {
	conn, err := menuUpgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		return
	}
	client := &menuClient{conn: conn, send: make(chan []byte, 8)}
	menuSockets.add(client)
	go client.writePump()
	go client.readPump()
	if payload, err := menu.SnapshotJSON(); err == nil {
		menuSockets.trySend(client, payload)
	}
}

type menuClient struct {
	conn *websocket.Conn
	send chan []byte
}

func (c *menuClient) readPump() {
	defer menuSockets.remove(c)
	c.conn.SetReadLimit(1024)
	_ = c.conn.SetReadDeadline(time.Now().Add(menuPongWait))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(menuPongWait))
	})
	for {
		if _, _, err := c.conn.ReadMessage(); err != nil {
			return
		}
	}
}

func (c *menuClient) writePump() {
	ticker := time.NewTicker(menuPingPeriod)
	defer ticker.Stop()
	defer c.conn.Close()
	for {
		select {
		case payload, ok := <-c.send:
			if !ok {
				return
			}
			_ = c.conn.SetWriteDeadline(time.Now().Add(menuWriteWait))
			if err := c.conn.WriteMessage(websocket.TextMessage, payload); err != nil {
				return
			}
		case <-ticker.C:
			_ = c.conn.SetWriteDeadline(time.Now().Add(menuWriteWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

type menuHub struct {
	mu      sync.Mutex
	clients map[*menuClient]struct{}
}

func newMenuHub() *menuHub {
	return &menuHub{clients: make(map[*menuClient]struct{})}
}

func (h *menuHub) add(c *menuClient) {
	h.mu.Lock()
	h.clients[c] = struct{}{}
	h.mu.Unlock()
}

func (h *menuHub) remove(c *menuClient) {
	h.mu.Lock()
	if _, ok := h.clients[c]; ok {
		delete(h.clients, c)
		close(c.send)
	}
	h.mu.Unlock()
}

func (h *menuHub) len() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

func (h *menuHub) trySend(c *menuClient, payload []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.clients[c]; !ok {
		return
	}
	select {
	case c.send <- payload:
	default:
	}
}

func (h *menuHub) broadcast(payload []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		select {
		case c.send <- payload:
		default:
		}
	}
}

func broadcastMenu() {
	ticker := time.NewTicker(menuPushInterval)
	defer ticker.Stop()
	var last []byte
	for range ticker.C {
		if menuSockets.len() == 0 {
			continue
		}
		payload, err := menu.SnapshotJSON()
		if err != nil || bytes.Equal(payload, last) {
			continue
		}
		last = append([]byte(nil), payload...)
		menuSockets.broadcast(payload)
	}
}
