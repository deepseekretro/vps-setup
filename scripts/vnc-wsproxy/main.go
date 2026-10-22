// vnc-wsproxy: a single-process WebSocket <-> TCP(VNC) proxy.
//
// One process can serve any number of VNC ports, e.g.:
//
//	vnc-wsproxy -map 127.0.0.1:6081=127.0.0.1:5901 \
//	            -map 127.0.0.1:6082=127.0.0.1:5902 \
//	            -map 127.0.0.1:6083=127.0.0.1:5903
//
// It only speaks the WebSocket transport. noVNC speaks RFB inside binary
// frames; the proxy never parses RFB, it just pipes bytes. TLS is terminated
// by nginx in front of it, so listeners stay on 127.0.0.1.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

type mapping struct {
	listen string
	target string
}

type mapList []mapping

func (m *mapList) String() string {
	parts := make([]string, 0, len(*m))
	for _, x := range *m {
		parts = append(parts, x.listen+"="+x.target)
	}
	return strings.Join(parts, ",")
}

func (m *mapList) Set(v string) error {
	l, t, ok := strings.Cut(v, "=")
	if !ok {
		return fmt.Errorf("want LISTEN=TARGET, got %q", v)
	}
	l, t = withDefaultHost(l), withDefaultHost(t)
	if _, _, err := net.SplitHostPort(l); err != nil {
		return fmt.Errorf("bad listen address %q: %w", l, err)
	}
	if _, _, err := net.SplitHostPort(t); err != nil {
		return fmt.Errorf("bad target address %q: %w", t, err)
	}
	for _, x := range *m {
		if x.listen == l {
			return fmt.Errorf("duplicate listen address %q", l)
		}
	}
	*m = append(*m, mapping{l, t})
	return nil
}

// withDefaultHost turns "6081" into "127.0.0.1:6081". ":6081" is kept as-is
// (all interfaces) for people who really want that.
func withDefaultHost(s string) string {
	if _, _, err := net.SplitHostPort(s); err == nil {
		return s
	}
	if strings.HasPrefix(s, ":") {
		return "127.0.0.1" + s
	}
	return "127.0.0.1:" + s
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  64 << 10,
	WriteBufferSize: 64 << 10,
	// noVNC asks for "binary"; base64 mode is not supported.
	Subprotocols: []string{"binary"},
	// The listener is loopback-only and nginx is the public gate.
	CheckOrigin: func(*http.Request) bool { return true },
}

type conn struct {
	ws     *websocket.Conn
	tcp    net.Conn
	once   sync.Once
	remote string
	target string
}

func (c *conn) close() {
	c.once.Do(func() {
		c.ws.Close()
		c.tcp.Close()
		log.Printf("close %s -> %s", c.remote, c.target)
	})
}

var live sync.Map // *conn -> struct{}

func handle(w http.ResponseWriter, r *http.Request, target string) {
	if !websocket.IsWebSocketUpgrade(r) {
		http.Error(w, "this endpoint only speaks WebSocket", http.StatusUpgradeRequired)
		return
	}

	// Dial first: a dead VNC port should produce a clean 502 before the
	// upgrade, so noVNC reports "failed" instead of an instant disconnect.
	up, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		log.Printf("dial %s: %v", target, err)
		http.Error(w, "VNC target unreachable", http.StatusBadGateway)
		return
	}
	if tc, ok := up.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(30 * time.Second)
	}

	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		up.Close()
		return
	}

	c := &conn{ws: ws, tcp: up, remote: r.RemoteAddr, target: target}
	live.Store(c, struct{}{})
	log.Printf("open %s -> %s", r.RemoteAddr, target)
	defer func() {
		live.Delete(c)
		c.close()
	}()

	var writeMu sync.Mutex
	writeWS := func(mt int, b []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = ws.SetWriteDeadline(time.Now().Add(30 * time.Second))
		return ws.WriteMessage(mt, b)
	}

	done := make(chan struct{})
	defer close(done)
	go func() {
		t := time.NewTicker(25 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				if err := writeWS(websocket.PingMessage, nil); err != nil {
					return
				}
			case <-done:
				return
			}
		}
	}()

	errc := make(chan error, 2)

	// VNC TCP -> browser
	go func() {
		buf := make([]byte, 64<<10)
		for {
			n, rerr := up.Read(buf)
			if n > 0 {
				if werr := writeWS(websocket.BinaryMessage, buf[:n]); werr != nil {
					errc <- werr
					return
				}
			}
			if rerr != nil {
				errc <- rerr
				return
			}
		}
	}()

	// browser -> VNC TCP
	go func() {
		ws.SetReadLimit(16 << 20)
		_ = ws.SetReadDeadline(time.Now().Add(90 * time.Second))
		ws.SetPongHandler(func(string) error {
			return ws.SetReadDeadline(time.Now().Add(90 * time.Second))
		})
		for {
			mt, data, rerr := ws.ReadMessage()
			if rerr != nil {
				errc <- rerr
				return
			}
			if mt != websocket.BinaryMessage {
				errc <- fmt.Errorf("unexpected websocket message type %d", mt)
				return
			}
			if _, werr := up.Write(data); werr != nil {
				errc <- werr
				return
			}
		}
	}()

	<-errc
}

func main() {
	var maps mapList
	flag.Var(&maps, "map", "LISTEN=TARGET (repeatable), e.g. 127.0.0.1:6081=127.0.0.1:5901")
	flag.Parse()
	if len(maps) == 0 {
		fmt.Fprintln(os.Stderr, "vnc-wsproxy: at least one -map is required")
		flag.Usage()
		os.Exit(2)
	}

	var servers []*http.Server
	var wg sync.WaitGroup
	for _, m := range maps {
		m := m
		mux := http.NewServeMux()
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			handle(w, r, m.target)
		})
		srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}

		ln, err := net.Listen("tcp", m.listen)
		if err != nil {
			log.Fatalf("listen %s: %v", m.listen, err)
		}
		log.Printf("listen %s -> %s", m.listen, m.target)
		servers = append(servers, srv)

		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
				log.Printf("serve %s: %v", m.listen, err)
			}
		}()
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Printf("shutting down")

	for _, s := range servers {
		_ = s.Close()
	}
	live.Range(func(k, _ any) bool {
		k.(*conn).close()
		return true
	})
	wg.Wait()
}
