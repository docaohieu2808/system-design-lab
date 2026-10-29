package main

// Capstone 13.4: chat rooms over WebSockets, in one app copy.
//
//	GET  /ws?room=R              join room R; every message posted to R is pushed to this connection
//	POST /api/rooms/{room}/send  body = the message; sent to everyone in the room; the server stamps the send time
//	GET  /stats/chat             connections open, messages delivered, and the process's memory in use

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

type room struct {
	mu    sync.Mutex
	conns map[*websocket.Conn]chan []byte
}

var (
	roomsMu   sync.Mutex
	rooms     = map[string]*room{}
	openConns atomic.Int64
	delivered atomic.Int64
)

func getRoom(name string) *room {
	roomsMu.Lock()
	defer roomsMu.Unlock()
	r := rooms[name]
	if r == nil {
		r = &room{conns: map[*websocket.Conn]chan []byte{}}
		rooms[name] = r
	}
	return r
}

func joinRoom(w http.ResponseWriter, r *http.Request) {
	c, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	rm, out := getRoom(r.URL.Query().Get("room")), make(chan []byte, 64)
	rm.mu.Lock()
	rm.conns[c] = out
	rm.mu.Unlock()
	openConns.Add(1)
	defer func() {
		rm.mu.Lock()
		delete(rm.conns, c)
		rm.mu.Unlock()
		openConns.Add(-1)
		c.CloseNow()
	}()
	ctx := c.CloseRead(context.Background()) // clients only listen; this notices when they leave
	for {
		select {
		case <-ctx.Done():
			return
		case msg := <-out:
			wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := c.Write(wctx, websocket.MessageText, msg)
			cancel()
			if err != nil {
				return
			}
			delivered.Add(1)
		}
	}
}

func sendToRoom(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(io.LimitReader(r.Body, 4096))
	msg, _ := json.Marshal(map[string]any{"sent_ms": time.Now().UnixMilli(), "text": string(body)})
	rm := getRoom(r.PathValue("room"))
	rm.mu.Lock()
	n := 0
	for _, out := range rm.conns {
		select {
		case out <- msg:
			n++
		default: // a client too slow to keep up loses this message instead of slowing down everyone else
		}
	}
	rm.mu.Unlock()
	w.Write([]byte(strconv.Itoa(n)))
}

func chatStats(w http.ResponseWriter, r *http.Request) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"connections": openConns.Load(), "delivered": delivered.Load(),
		"heap_mb": float64(ms.HeapInuse) / 1048576, "sys_mb": float64(ms.Sys) / 1048576, "goroutines": runtime.NumGoroutine()})
}
