// vnc-rtc bridge：WebRTC DataChannel ⇄ 本机 VNC TCP 端口
//
//   POST /offer?screen=1|2|test   {sdp,type:offer} → {sdp,type:answer}
//   GET  /health
//
// ICE 端口固定在一小段 UDP 上（宿主机按段 DNAT 进来），并通过 NAT 1:1
// 把候选地址改写成公网 IP，这样浏览器能直连，不需要 TURN。
package main

import (
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"
)

var (
	flagListen   = flag.String("listen", "127.0.0.1:6091", "信令 HTTP 监听地址")
	flagPublicIP = flag.String("public-ip", "", "对外播报的公网 IP（NAT 1:1），留空则用本机地址")
	flagPortMin  = flag.Int("port-min", 8190, "ICE UDP 端口下限")
	flagPortMax  = flag.Int("port-max", 8193, "ICE UDP 端口上限")
	flagTarget1  = flag.String("target1", "127.0.0.1:5901", "主屏 VNC 地址")
	flagTarget2  = flag.String("target2", "127.0.0.1:5902", "第二块屏 VNC 地址")
	flagTestTgt  = flag.String("test-target", "", "仅测试用：screen=test 的目标（默认关闭）")
	flagBindIP   = flag.String("bind-ip", "", "只在这个本机地址上收 ICE（默认用默认路由地址）")
	flagMinCwnd  = flag.Int("sctp-min-cwnd", 0, "SCTP 最小拥塞窗口（字节，0=库默认）")
	flagMaxMsg   = flag.Int("sctp-max-message", 262144, "SCTP 最大消息尺寸（字节）")
	flagChunk    = flag.Int("chunk", 65536, "每次从 TCP 读多少字节再 Send（调大可减少开销）")
)

type offerReq struct {
	SDP  string `json:"sdp"`
	Type string `json:"type"`
}

type answerResp struct {
	SDP  string `json:"sdp"`
	Type string `json:"type"`
}

var api *webrtc.API

// 容器 eth0 上有两个 IPv4（10.0.0.2 静态 + 10.0.0.138 DHCP 次地址）。
// 不过滤的话一个 PeerConnection 会占两个端口，4 个端口只够 2 条连接。
func primaryIP() net.IP {
	conn, err := net.Dial("udp4", "1.1.1.1:53")
	if err != nil {
		return nil
	}
	defer conn.Close()
	if a, ok := conn.LocalAddr().(*net.UDPAddr); ok {
		return a.IP
	}
	return nil
}

func buildAPI() *webrtc.API {
	se := webrtc.SettingEngine{}
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	se.SetIncludeLoopbackCandidate(false)

	if err := se.SetEphemeralUDPPortRange(uint16(*flagPortMin), uint16(*flagPortMax)); err != nil {
		log.Fatalf("端口范围无效: %v", err)
	}
	if *flagPublicIP != "" {
		se.SetNAT1To1IPs([]string{*flagPublicIP}, webrtc.ICECandidateTypeHost)
	}
	ip := net.ParseIP(*flagBindIP)
	if ip == nil {
		ip = primaryIP()
	}
	if ip != nil && ip.IsLoopback() {
		se.SetIncludeLoopbackCandidate(true) // 仅本地测试用
	}
	if ip != nil {
		log.Printf("只使用本机地址 %s", ip)
		se.SetIPFilter(func(a net.IP) bool { return a.Equal(ip) })
	}
	if *flagMinCwnd > 0 {
		se.SetSCTPMinCwnd(uint32(*flagMinCwnd))
		log.Printf("SCTP 最小 cwnd = %d 字节", *flagMinCwnd)
	}
	if *flagMaxMsg > 0 {
		se.SetSCTPMaxMessageSize(uint32(*flagMaxMsg))
	}
	return webrtc.NewAPI(webrtc.WithSettingEngine(se))
}

func main() {
	flag.Parse()
	api = buildAPI()
	log.Printf("信令监听 %s，ICE UDP %d-%d，公网 IP %q", *flagListen, *flagPortMin, *flagPortMax, *flagPublicIP)

	mux := http.NewServeMux()
	mux.HandleFunc("/offer", handleOffer)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "ok\n")
	})

	srv := &http.Server{
		Addr:              *flagListen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      15 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func handleOffer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}

	var target string
	switch r.URL.Query().Get("screen") {
	case "", "1":
		target = *flagTarget1
	case "2":
		target = *flagTarget2
	case "test":
		if *flagTestTgt == "" {
			http.Error(w, "test target disabled", http.StatusBadRequest)
			return
		}
		target = *flagTestTgt
	default:
		http.Error(w, "bad screen", http.StatusBadRequest)
		return
	}

	var req offerReq
	body := http.MaxBytesReader(w, r.Body, 512*1024)
	if err := json.NewDecoder(body).Decode(&req); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.Type != "offer" || req.SDP == "" {
		http.Error(w, "expect offer", http.StatusBadRequest)
		return
	}

	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		log.Printf("NewPeerConnection: %v", err)
		http.Error(w, "pc: "+err.Error(), http.StatusInternalServerError)
		return
	}

	var dcSeen atomic.Bool
	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		dcSeen.Store(true)
		log.Printf("DataChannel %q 已建立，目标 %s", dc.Label(), target)
		dc.OnOpen(func() { go pump(dc, target, func() { _ = pc.Close() }) })
		/* 前端关页面/断线 → 立刻释放这个 PeerConnection，把 UDP 端口还回去。
		   否则要等 ICE 的 failed 超时（几十秒），4 个端口很容易被重连耗光。 */
		dc.OnClose(func() {
			go func() {
				time.Sleep(2 * time.Second)
				_ = pc.Close()
			}()
		})
	})

	gathered := make(chan struct{})
	var once sync.Once
	pc.OnICEGatheringStateChange(func(s webrtc.ICEGatheringState) {
		if s == webrtc.ICEGatheringStateComplete {
			once.Do(func() { close(gathered) })
		}
	})

	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		log.Printf("连接状态: %s", s)
		switch s {
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			_ = pc.Close()
		}
	})

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer, SDP: req.SDP,
	}); err != nil {
		log.Printf("SetRemoteDescription: %v", err)
		http.Error(w, "sdp: "+err.Error(), http.StatusBadRequest)
		_ = pc.Close()
		return
	}

	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		log.Printf("CreateAnswer: %v", err)
		http.Error(w, "answer: "+err.Error(), http.StatusInternalServerError)
		_ = pc.Close()
		return
	}
	if err := pc.SetLocalDescription(answer); err != nil {
		log.Printf("SetLocalDescription: %v", err)
		http.Error(w, "sdp: "+err.Error(), http.StatusInternalServerError)
		_ = pc.Close()
		return
	}

	select {
	case <-gathered:
	case <-time.After(5 * time.Second):
		log.Printf("ICE 收集超时，按当前候选返回")
	}

	/* 客户端拿到 answer 却一直连不上（例如 UDP 被墙），别把端口占着 */
	go func() {
		time.Sleep(30 * time.Second)
		switch pc.ConnectionState() {
		case webrtc.PeerConnectionStateNew, webrtc.PeerConnectionStateConnecting:
			log.Printf("30s 内没连上，释放该连接的端口")
			_ = pc.Close()
		default:
			/* ICE 连上了但一直没建 DataChannel：同样是个占着端口的空壳 */
			if !dcSeen.Load() {
				log.Printf("30s 内没建 DataChannel，释放该连接的端口")
				_ = pc.Close()
			}
		}
	}()

	local := pc.LocalDescription()
	if local == nil {
		http.Error(w, "no local description", http.StatusInternalServerError)
		_ = pc.Close()
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(answerResp{SDP: local.SDP, Type: local.Type.String()})
}

// pump：DataChannel ⇄ TCP 双向转发。onEnd 用来把 PeerConnection 一起关掉。
func pump(dc *webrtc.DataChannel, target string, onEnd func()) {
	conn, err := net.DialTimeout("tcp", target, 3*time.Second)
	if err != nil {
		log.Printf("连接 %s 失败: %v", target, err)
		_ = dc.Close()
		onEnd()
		return
	}
	log.Printf("TCP 已连到 %s", target)
	start := time.Now()
	var up, down int64

	var once sync.Once
	done := make(chan struct{})
	closeAll := func() {
		once.Do(func() {
			close(done)
			_ = conn.Close()
			_ = dc.Close()
			/* 必须连 PeerConnection 一起关：pump 里注册 dc.OnClose 会覆盖
			   OnDataChannel 里那个“2 秒后 pc.Close()”，不在这里补一刀的话，
			   ICE 会继续对着已结束的会话发 keepalive，819x 的 UDP 端口永远不释放
			   （实测重连几次就把 4 个端口占满，新连接只能卡在协商阶段）。 */
			if onEnd != nil {
				onEnd()
			}
		})
	}

	/* 浏览器被强杀 / 网络断掉时，DataChannel 不一定回调 OnClose，
	   这里盯着 DC 状态，一旦不是 open 就把 TCP 连接收掉。
	   否则 x11vnc 会一直对着死连接推画面（实测会留下僵尸连接）。 */
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				if dc.ReadyState() != webrtc.DataChannelStateOpen {
					closeAll()
					return
				}
			}
		}
	}()

	dc.OnClose(closeAll)

	// DataChannel → TCP（OnMessage 在单 goroutine 里串行回调，无需加锁）
	dc.OnMessage(func(m webrtc.DataChannelMessage) {
		up += int64(len(m.Data))
		if _, err := conn.Write(m.Data); err != nil {
			closeAll()
		}
	})

	// TCP → DataChannel（16KB 分片；SCTP 有缓冲，过多时稍等）
	go func() {
		buf := make([]byte, *flagChunk)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				down += int64(n)
				/* 等 SCTP 把缓冲吐出去。如果对端已经死了（浏览器被关/断网），
				   ICE 要几十秒才判 failed，这期间 BufferedAmount 完全不降。
				   8 秒没有任何下降就认为对端没了，直接收摊。 */
				lastAmt := ^uint64(0)
				var stallStart time.Time
				for dc.BufferedAmount() > 512*1024 {
					select {
					case <-done:
						return
					default:
					}
					amt := dc.BufferedAmount()
					if amt < lastAmt {
						stallStart = time.Time{}
					} else if stallStart.IsZero() {
						stallStart = time.Now()
					} else if time.Since(stallStart) > 8*time.Second {
						log.Printf("发送缓冲 %.1f MB 连续 8s 无进展，判定对端已断",
							float64(amt)/1048576)
						closeAll()
						return
					}
					lastAmt = amt
					time.Sleep(2 * time.Millisecond)
				}
				if serr := dc.Send(buf[:n]); serr != nil {
					log.Printf("发送失败: %v", serr)
					break
				}
			}
			if err != nil {
				break
			}
		}
		el := time.Since(start).Seconds()
		log.Printf("连接结束 %s：上行 %.2f MB 下行 %.2f MB，%.1fs（下行 %.2f MB/s）",
			target, float64(up)/1048576, float64(down)/1048576, el, float64(down)/el/1048576)
		closeAll()
	}()
}

func init() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.SetOutput(os.Stderr)
}
