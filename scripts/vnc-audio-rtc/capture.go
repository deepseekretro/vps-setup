package main

import (
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jfreymuth/pulse"
	"github.com/jfreymuth/pulse/proto"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/thesyncim/gopus"
)

const (
	audioSampleRate     = 48000
	audioChannels       = 2
	audioFrameSamples   = 480 // 10 ms
	audioFrameBytes     = audioFrameSamples * audioChannels * 2
	audioFrameDuration  = 10 * time.Millisecond
	audioMaxPacket      = 4000
	audioDefaultBitrate = 192000
)

// goAudioPublisher 是 AUDIO_BACKEND=go 时的采集/编码端：
// PulseAudio monitor → gopus（10ms Opus）→ TrackLocalStaticSample。
// 没有外部进程，也不使用本机 RTP 端口。
type goAudioPublisher struct {
	track   *webrtc.TrackLocalStaticSample
	client  *pulse.Client
	stream  *pulse.RecordStream
	enc     *gopus.Encoder
	pkt     []byte
	pcm     []int16
	source  string
	bitrate int

	frames   atomic.Uint64
	bytes    atomic.Uint64
	stopOnce sync.Once
	errOnce  sync.Once
	onError  func(error)
}

func newGoAudioPublisher(track *webrtc.TrackLocalStaticSample) *goAudioPublisher {
	return &goAudioPublisher{
		track: track,
		pkt:   make([]byte, audioMaxPacket),
	}
}

// desktopAudioValue 读取 /etc/default/desktop-audio。每次按需启动采集时重读，
// 这样改码率/采集源和 ffmpeg 后端一样，下一个听众就生效，不用重启服务。
// 文件里的值优先于进程环境；文件不存在时退回环境变量。
func desktopAudioValue(key string) (string, bool) {
	path := strings.TrimSpace(os.Getenv("DESKTOP_AUDIO_ENV"))
	if path == "" {
		path = "/etc/default/desktop-audio"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok || strings.TrimSpace(k) != key {
			continue
		}
		v = strings.TrimSpace(v)
		v = strings.Trim(v, `"'`)
		return v, true
	}
	return "", false
}

func audioSource() string {
	if v, ok := desktopAudioValue("DESKTOP_AUDIO_SRC"); ok && v != "" {
		return v
	}
	if s := strings.TrimSpace(os.Getenv("DESKTOP_AUDIO_SRC")); s != "" {
		return s
	}
	return "virtual_speaker.monitor"
}

// audioBitrate 优先读 /etc/default/desktop-audio 的 DESKTOP_AUDIO_BITRATE，
// 支持 192k / 192000 两种写法。
func audioBitrate() (int, error) {
	raw := ""
	if v, ok := desktopAudioValue("DESKTOP_AUDIO_BITRATE"); ok {
		raw = strings.TrimSpace(v)
	}
	if raw == "" {
		raw = strings.TrimSpace(os.Getenv("DESKTOP_AUDIO_BITRATE"))
	}
	if raw == "" {
		return audioDefaultBitrate, nil
	}
	v := strings.ToLower(raw)
	mult := 1
	if strings.HasSuffix(v, "k") {
		mult = 1000
		v = strings.TrimSuffix(v, "k")
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("DESKTOP_AUDIO_BITRATE=%q 不合法", raw)
	}
	bps := n * mult
	if bps < 6000 || bps > 512000 {
		return 0, fmt.Errorf("DESKTOP_AUDIO_BITRATE=%q 超出 6k~512k", raw)
	}
	return bps, nil
}

func (p *goAudioPublisher) start() error {
	src := audioSource()
	bitrate, err := audioBitrate()
	if err != nil {
		return err
	}

	enc, err := gopus.NewEncoder(gopus.EncoderConfig{
		SampleRate:  audioSampleRate,
		Channels:    audioChannels,
		Application: gopus.ApplicationAudio,
	})
	if err != nil {
		return fmt.Errorf("创建 gopus 编码器: %w", err)
	}
	if err := enc.SetBitrate(bitrate); err != nil {
		return fmt.Errorf("设置 Opus 码率 %d: %w", bitrate, err)
	}
	if err := enc.SetFrameSize(audioFrameSamples); err != nil {
		return fmt.Errorf("设置 Opus 帧长 10ms: %w", err)
	}
	if err := enc.SetComplexity(10); err != nil {
		return fmt.Errorf("设置 Opus complexity: %w", err)
	}

	client, err := pulse.NewClient()
	if err != nil {
		return fmt.Errorf("连接 PulseAudio: %w", err)
	}
	opts := []pulse.RecordOption{
		pulse.RecordSampleRate(audioSampleRate),
		pulse.RecordChannels(proto.ChannelMap{proto.ChannelFrontLeft, proto.ChannelFrontRight}),
	}

	// 默认源是 virtual_speaker.monitor；有同名 sink 时按 monitor 录，
	// 否则退回按 source 名称查找，兼容用户改成别的 PulseAudio 源。
	if strings.HasSuffix(src, ".monitor") {
		sinkName := strings.TrimSuffix(src, ".monitor")
		sink, sinkErr := client.SinkByID(sinkName)
		if sinkErr == nil {
			opts = append(opts, pulse.RecordMonitor(sink))
		} else {
			source, sourceErr := client.SourceByID(src)
			if sourceErr != nil {
				client.Close()
				return fmt.Errorf("找 PulseAudio 源 %q: sink=%v source=%v", src, sinkErr, sourceErr)
			}
			opts = append(opts, pulse.RecordSource(source))
		}
	} else {
		source, sourceErr := client.SourceByID(src)
		if sourceErr != nil {
			client.Close()
			return fmt.Errorf("找 PulseAudio 源 %q: %w", src, sourceErr)
		}
		opts = append(opts, pulse.RecordSource(source))
	}
	opts = append(opts, pulse.RecordBufferFragmentSize(audioFrameBytes))

	w := pulse.Int16Writer(func(in []int16) (int, error) {
		if err := p.writePCM(in); err != nil {
			p.fail(err)
			return 0, err
		}
		return len(in), nil
	})

	stream, err := client.NewRecord(w, opts...)
	if err != nil {
		client.Close()
		return fmt.Errorf("创建 PulseAudio 录制流: %w", err)
	}

	p.client = client
	p.stream = stream
	p.enc = enc
	p.source = src
	p.bitrate = bitrate

	stream.Start()
	log.Printf("Go 音频采集：%s → gopus（%d bps，10ms，48kHz 立体声）", src, bitrate)
	return nil
}

func (p *goAudioPublisher) writePCM(in []int16) error {
	p.pcm = append(p.pcm, in...)
	need := audioFrameSamples * audioChannels
	for len(p.pcm) >= need {
		n, err := p.enc.EncodeInt16(p.pcm[:need], p.pkt)
		if err != nil {
			return fmt.Errorf("Opus 编码: %w", err)
		}
		if n > 0 {
			// WriteSample 之后这块数据要交给 pion 打包，复制一份避免复用 pkt。
			data := make([]byte, n)
			copy(data, p.pkt[:n])
			if err := p.track.WriteSample(media.Sample{
				Data:     data,
				Duration: audioFrameDuration,
			}); err != nil {
				// 单个 PeerConnection 坏掉时 WriteSample 会返回错误；
				// 其他听众仍然正常，不能因此停掉整条采集。
				log.Printf("写 WebRTC 音轨失败（继续采集）: %v", err)
			}
			p.frames.Add(1)
			p.bytes.Add(uint64(n))
			opusFrames.Add(1)
			opusBytes.Add(uint64(n))
		}
		p.pcm = p.pcm[need:]
	}
	if len(p.pcm) == 0 {
		p.pcm = p.pcm[:0]
	}
	return nil
}

func (p *goAudioPublisher) fail(err error) {
	p.errOnce.Do(func() {
		log.Printf("Go 音频采集异常: %v", err)
		if p.onError != nil {
			go p.onError(err)
		}
	})
}

func (p *goAudioPublisher) stop() {
	p.stopOnce.Do(func() {
		if p.stream != nil {
			p.stream.Stop()
		}
		if p.client != nil {
			p.client.Close()
		}
		log.Printf("Go 音频采集停止：%d 帧 / %d 字节", p.frames.Load(), p.bytes.Load())
	})
}
