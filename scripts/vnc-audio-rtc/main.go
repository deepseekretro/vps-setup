// vnc-audio-rtc：桌面声音 → 浏览器，直接走 WebRTC，不过 MediaMTX。
//
//	AUDIO_BACKEND=go（默认）：
//	  PulseAudio monitor → gopus（本进程内编码） → pion → SRTP/UDP 8193 → 浏览器
//
//	AUDIO_BACKEND=ffmpeg：
//	  PulseAudio monitor → ffmpeg(libopus) → RTP/UDP 127.0.0.1:8195
//	                                           ↓
//	                     本进程 (pion) → SRTP/UDP 8193 → 浏览器
//
// 两种后端都是采集、编码、ICE 发送一条直线，没有 RTSP/TCP 中转，也没有
// MediaMTX 二次转发。go 后端不占 8195，也没有外部 ffmpeg 进程。
//
//	POST /whep   application/sdp  offer → answer（非 trickle，返回前等 ICE 收集完）
//	GET  /health
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

var (
	flagListen   = flag.String("listen", "127.0.0.1:6092", "WHEP 信令 HTTP 监听地址")
	flagPublicIP = flag.String("public-ip", "", "对外播报的公网 IP（NAT 1:1），留空则用本机地址")
	flagBindIP   = flag.String("bind-ip", "", "只在这个本机地址上收 ICE（默认用默认路由地址）")
	flagICEPort  = flag.Int("ice-port", 8193, "ICE UDP 复用端口（宿主机需已 DNAT 进来）")
	flagRTPAddr  = flag.String("rtp", "127.0.0.1:8195", "ffmpeg 后端收 RTP 的本机 UDP 地址")
	flagPublish  = flag.String("publish", "/usr/local/bin/desktop-audio-rtc-publish", "ffmpeg 后端按需拉起的音频发布脚本")
	flagIdle     = flag.Duration("idle-stop", 5*time.Second, "最后一个听众离开后多久停编码")
	flagBackend  = flag.String("audio-backend", defaultAudioBackend(), "音频后端：go（默认，进程内 PulseAudio+gopus）或 ffmpeg（外部 ffmpeg → 本机 RTP）")
)

var (
	api          *webrtc.API
	audioBackend string
	rtpTrack     *webrtc.TrackLocalStaticRTP
	sampleTrack  *webrtc.TrackLocalStaticSample

	viewersMu sync.Mutex
	viewers   int
	idleTimer *time.Timer

	pubMu  sync.Mutex
	pubCmd *exec.Cmd
	goPub  *goAudioPublisher

	rtpCount   atomic.Uint64
	opusFrames atomic.Uint64
	opusBytes  atomic.Uint64
)

func defaultAudioBackend() string {
	b := strings.ToLower(strings.TrimSpace(os.Getenv("AUDIO_BACKEND")))
	if b == "" {
		return "go"
	}
	return b
}

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

func buildAPI() (*webrtc.API, net.PacketConn, error) {
	se := webrtc.SettingEngine{}
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	se.SetIncludeLoopbackCandidate(false)

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
		se.SetIPFilter(func(a net.IP) bool { return a.Equal(ip) })
	}

	// 所有 PeerConnection 复用同一个 UDP 端口。宿主机只需要 DNAT 这一个端口，
	// 也不会像临时端口那样几个听众就把 8190-8193 占满。
	conn, err := net.ListenPacket("udp4", net.JoinHostPort(ip.String(), fmt.Sprint(*flagICEPort)))
	if err != nil {
		return nil, nil, fmt.Errorf("绑定 ICE UDP %s:%d 失败: %w", ip, *flagICEPort, err)
	}
	se.SetICEUDPMux(webrtc.NewICEUDPMux(nil, conn))

	return webrtc.NewAPI(webrtc.WithSettingEngine(se)), conn, nil
}

func startPublisher() {
	if audioBackend == "go" {
		startGoPublisher()
		return
	}

	pubMu.Lock()
	if pubCmd != nil {
		pubMu.Unlock()
		return
	}
	cmd := exec.Command(*flagPublish)
	cmd.Env = append(os.Environ(), "DESKTOP_AUDIO_RTP=rtp://"+*flagRTPAddr)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		pubMu.Unlock()
		log.Printf("拉不起音频发布器: %v", err)
		return
	}
	pubCmd = cmd
	pubMu.Unlock()
	log.Printf("音频发布器已启动 pid=%d", cmd.Process.Pid)

	go func() {
		err := cmd.Wait()
		pubMu.Lock()
		if pubCmd == cmd {
			pubCmd = nil
		}
		pubMu.Unlock()
		log.Printf("音频发布器退出: %v", err)

		retryPublisherIfViewed()
	}()
}

func startGoPublisher() {
	pubMu.Lock()
	defer pubMu.Unlock()
	if goPub != nil {
		return
	}
	if sampleTrack == nil {
		log.Printf("Go 音频音轨未初始化，无法启动采集")
		return
	}
	p := newGoAudioPublisher(sampleTrack)
	p.onError = func(err error) {
		// 编码器/采集流内部错误：稍等回调退出后停掉，再按需重试。
		time.AfterFunc(100*time.Millisecond, func() {
			pubMu.Lock()
			if goPub == p {
				goPub = nil
			}
			pubMu.Unlock()
			p.stop()
			retryPublisherIfViewed()
		})
	}
	if err := p.start(); err != nil {
		log.Printf("Go 音频采集启动失败: %v", err)
		p.stop()
		retryPublisherIfViewed()
		return
	}
	goPub = p
	log.Printf("Go 音频采集已启动")
}

func stopGoPublisher() {
	pubMu.Lock()
	p := goPub
	goPub = nil
	pubMu.Unlock()
	if p != nil {
		p.stop()
	}
}

func stopPublisher() {
	if audioBackend == "go" {
		stopGoPublisher()
		return
	}

	pubMu.Lock()
	cmd := pubCmd
	pubCmd = nil
	pubMu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	pid := cmd.Process.Pid
	time.AfterFunc(2*time.Second, func() { _ = cmd.Process.Kill() })
	log.Printf("音频发布器已停止 pid=%d", pid)
}

func publisherRunning() bool {
	pubMu.Lock()
	defer pubMu.Unlock()
	if audioBackend == "go" {
		return goPub != nil
	}
	return pubCmd != nil
}

func retryPublisherIfViewed() {
	viewersMu.Lock()
	n := viewers
	viewersMu.Unlock()
	if n == 0 {
		return
	}
	time.AfterFunc(2*time.Second, func() {
		viewersMu.Lock()
		n := viewers
		viewersMu.Unlock()
		if n > 0 {
			startPublisher()
		}
	})
}

func addViewer() {
	viewersMu.Lock()
	viewers++
	if idleTimer != nil {
		idleTimer.Stop()
		idleTimer = nil
	}
	n := viewers
	viewersMu.Unlock()
	if n == 1 {
		startPublisher()
	}
	log.Printf("听众接入，当前 %d", n)
}

func removeViewer() {
	viewersMu.Lock()
	if viewers > 0 {
		viewers--
	}
	n := viewers
	if n == 0 {
		if idleTimer != nil {
			idleTimer.Stop()
		}
		idleTimer = time.AfterFunc(*flagIdle, func() {
			viewersMu.Lock()
			still := viewers == 0
			viewersMu.Unlock()
			if still {
				stopPublisher()
			}
		})
	}
	viewersMu.Unlock()
	log.Printf("听众断开，当前 %d", n)
}

func addAudioTrack(pc *webrtc.PeerConnection) error {
	if audioBackend == "go" {
		if sampleTrack == nil {
			return fmt.Errorf("Go 音频音轨未初始化")
		}
		_, err := pc.AddTrack(sampleTrack)
		return err
	}
	if rtpTrack == nil {
		return fmt.Errorf("ffmpeg RTP 音轨未初始化")
	}
	_, err := pc.AddTrack(rtpTrack)
	return err
}

func handleWHEP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil || len(body) == 0 {
		http.Error(w, "empty sdp", http.StatusBadRequest)
		return
	}

	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		http.Error(w, "pc: "+err.Error(), http.StatusInternalServerError)
		return
	}

	var once sync.Once
	drop := func() {
		once.Do(func() {
			removeViewer()
			_ = pc.Close()
		})
	}
	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		log.Printf("音频 PeerConnection: %s", s)
		switch s {
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			drop()
		case webrtc.PeerConnectionStateDisconnected:
			time.AfterFunc(10*time.Second, func() {
				if pc.ConnectionState() == webrtc.PeerConnectionStateDisconnected {
					drop()
				}
			})
		}
	})

	if err := addAudioTrack(pc); err != nil {
		drop()
		http.Error(w, "add track: "+err.Error(), http.StatusInternalServerError)
		return
	}

	offer := webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: string(body)}
	if err := pc.SetRemoteDescription(offer); err != nil {
		drop()
		http.Error(w, "offer: "+err.Error(), http.StatusBadRequest)
		return
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		drop()
		http.Error(w, "answer: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if err := pc.SetLocalDescription(answer); err != nil {
		drop()
		http.Error(w, "local: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// 页面发的是非 trickle offer，我们也返回带候选的完整 answer。
	select {
	case <-webrtc.GatheringCompletePromise(pc):
	case <-time.After(5 * time.Second):
	}

	local := pc.LocalDescription()
	if local == nil {
		drop()
		http.Error(w, "no local description", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/sdp")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	_, _ = io.WriteString(w, local.SDP)

	addViewer()
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	viewersMu.Lock()
	n := viewers
	viewersMu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok":           true,
		"backend":      audioBackend,
		"viewers":      n,
		"publisher":    publisherRunning(),
		"rtp_packets":  rtpCount.Load(),
		"opus_packets": opusFrames.Load(),
		"opus_bytes":   opusBytes.Load(),
	})
}

func rtpLoop(conn *net.UDPConn) {
	buf := make([]byte, 2048)
	for {
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("RTP 收包结束: %v", err)
			return
		}
		var pkt rtp.Packet
		if err := pkt.Unmarshal(buf[:n]); err != nil {
			continue
		}
		if c := rtpCount.Add(1); c == 1 || c%5000 == 0 {
			log.Printf("RTP 已收 %d 包", c)
		}
		if err := rtpTrack.WriteRTP(&pkt); err != nil {
			log.Printf("RTP 转发失败: %v", err)
		}
	}
}

func main() {
	flag.Parse()

	audioBackend = strings.ToLower(strings.TrimSpace(*flagBackend))
	switch audioBackend {
	case "go", "ffmpeg":
	default:
		log.Fatalf("AUDIO_BACKEND 只能是 go 或 ffmpeg，当前 %q", audioBackend)
	}

	codec := webrtc.RTPCodecCapability{
		MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2,
	}
	var err error
	if audioBackend == "go" {
		sampleTrack, err = webrtc.NewTrackLocalStaticSample(codec, "audio", "desktop")
	} else {
		rtpTrack, err = webrtc.NewTrackLocalStaticRTP(codec, "audio", "desktop")
	}
	if err != nil {
		log.Fatalf("创建音轨失败: %v", err)
	}

	var iceConn net.PacketConn
	api, iceConn, err = buildAPI()
	if err != nil {
		log.Fatalf("%v", err)
	}
	defer iceConn.Close()

	if audioBackend == "ffmpeg" {
		rtpAddr, err := net.ResolveUDPAddr("udp4", *flagRTPAddr)
		if err != nil {
			log.Fatalf("RTP 地址无效: %v", err)
		}
		rtpConn, err := net.ListenUDP("udp4", rtpAddr)
		if err != nil {
			log.Fatalf("绑定 RTP %s 失败: %v", rtpAddr, err)
		}
		defer rtpConn.Close()
		go rtpLoop(rtpConn)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/whep", handleWHEP)
	mux.HandleFunc("/health", handleHealth)

	srv := &http.Server{
		Addr:              *flagListen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      20 * time.Second,
	}

	log.Printf("音频 WebRTC：后端 %s，信令 %s，ICE UDP %s:%d", audioBackend, *flagListen, *flagBindIP, *flagICEPort)
	if audioBackend == "ffmpeg" {
		log.Printf("ffmpeg 后端：RTP 收 %s", *flagRTPAddr)
	} else {
		log.Printf("go 后端：进程内采集 %s（首个听众接入时启动）", audioSource())
	}

	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("HTTP: %v", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	log.Printf("退出中")
	stopPublisher()
	_ = srv.Close()
}
