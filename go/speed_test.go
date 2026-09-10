package agent

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

var speedStreams = map[string]string{
	"claude":    "event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":12}}}\n\nevent: message_delta\ndata: {\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":100}}\n\nevent: message_stop\ndata: {}\n\n",
	"openai":    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":100}}\n\ndata: [DONE]\n\n",
	"responses": "event: response.completed\ndata: {\"response\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":100}}}\n\n",
}

// 终态已刷新到客户端后，服务器仍保持 HTTP 正文打开。
func TestSpeedWaitsForHTTPEOF(t *testing.T) {
	for provider, stream := range speedStreams {
		t.Run(provider, func(t *testing.T) {
			terminal := make(chan struct{})
			release := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				fmt.Fprint(w, stream)
				w.(http.Flusher).Flush()
				close(terminal)
				<-release
				fmt.Fprint(w, ": 尾部\n\n")
			}))
			defer server.Close()
			tr := NewHTTPTransport(Config{Provider: provider, BaseURL: server.URL})
			ch, err := tr.Call(context.Background(), "[]", "", "[]", 128, "disabled")
			if err != nil {
				close(release)
				t.Fatal(err)
			}
			<-terminal
			timer := time.NewTimer(180 * time.Millisecond)
			early := false
		wait:
			for {
				select {
				case ev, ok := <-ch:
					if !ok {
						early = true
						break wait
					}
					if ev.Type == EventUsage || ev.Type == EventStop {
						early = true
					}
				case <-timer.C:
					break wait
				}
			}
			timer.Stop()
			releasedAt := time.Now().UnixMilli()
			close(release)
			var usage Usage
			count, stops := 0, 0
			for ev := range ch {
				if ev.Type == EventError {
					t.Errorf("意外错误: %v", ev.Fields)
				}
				if ev.Type == EventUsage {
					usage = ev.Payload.(Usage)
					count++
				}
				if ev.Type == EventStop {
					stops++
				}
			}
			if early {
				t.Error("HTTP 结束前发布了用量或停止事件")
			}
			if count != 1 || stops != 1 || !usage.Stopped || usage.OutputTokens != 100 || usage.InputTokens != 12 {
				t.Fatalf("终态不正确: 用量=%+v 次数=%d 停止=%d", usage, count, stops)
			}
			if usage.EndMs < releasedAt || usage.EndMs-usage.StartMs < 170 {
				t.Fatalf("计时未包含尾部等待: %+v", usage)
			}
			store := &FileStore{statsFile: filepath.Join(t.TempDir(), "stats.json")}
			if err := store.UpdateStats(usage, ""); err != nil {
				t.Fatal(err)
			}
			want := 100000 / int(usage.EndMs-usage.StartMs)
			if got := store.GetStats().LastCallSpeedTokPerSec; got != want {
				t.Fatalf("速度=%d 预期=%d", got, want)
			}
		})
	}
}

func TestSpeedFailurePreservesPrevious(t *testing.T) {
	for provider, stream := range speedStreams {
		modes := []string{"truncated", "cancel", "missing", "error", "retry-missing", "retry-success"}
		if provider == "responses" {
			modes = append(modes, "response.failed", "response.incomplete")
		}
		for _, mode := range modes {
			t.Run(provider+"/"+mode, func(t *testing.T) {
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.Header().Set("Content-Type", "text/event-stream")
					if mode == "truncated" {
						w.Header().Set("Content-Length", "100000")
					}
					if mode != "missing" {
						fmt.Fprint(w, stream)
					} else {
						fmt.Fprint(w, ": 未终结\n\n")
					}
					w.(http.Flusher).Flush()
					switch mode {
					case "cancel":
						time.Sleep(40 * time.Millisecond)
						cancel()
						<-r.Context().Done()
					case "error":
						fmt.Fprint(w, "event: error\ndata: {\"error\":{\"message\":\"失败\"}}\n\n")
					case "response.failed", "response.incomplete":
						fmt.Fprintf(w, "event: %s\ndata: {\"response\":{\"error\":{\"message\":\"失败\"},\"usage\":{\"output_tokens\":10}}}\n\n", mode)
					case "retry-missing", "retry-success":
						fmt.Fprint(w, "event: retry\ndata: {}\n\n")
						w.(http.Flusher).Flush()
						time.Sleep(40 * time.Millisecond)
						if mode == "retry-success" {
							fmt.Fprint(w, stream)
						}
					}
				}))
				defer server.Close()
				store := &FileStore{statsFile: filepath.Join(t.TempDir(), "stats.json")}
				if err := store.UpdateStats(Usage{Stopped: true, OutputTokens: 37, StartMs: 1000, EndMs: 2000}, ""); err != nil {
					t.Fatal(err)
				}
				tr := NewHTTPTransport(Config{Provider: provider, BaseURL: server.URL})
				ch, err := tr.Call(ctx, "[]", "", "[]", 128, "disabled")
				if err != nil {
					t.Fatal(err)
				}
				successes, retries, errors, stops := 0, 0, 0, 0
				for ev := range ch {
					switch ev.Type {
					case EventUsage:
						u := ev.Payload.(Usage)
						if u.Stopped {
							successes++
						}
						if err := store.UpdateStats(u, ""); err != nil {
							t.Fatal(err)
						}
					case EventRetry:
						retries++
					case EventError:
						errors++
					case EventStop:
						stops++
						if mode != "retry-success" && (len(ev.Fields) < 2 || ev.Fields[1] != "error") {
							t.Errorf("失败流停止原因错误: %v", ev.Fields)
						}
					}
				}
				if stops != 1 {
					t.Errorf("停止事件数=%d", stops)
				}
				if mode == "retry-success" {
					if successes != 1 || retries != 1 || errors != 0 {
						t.Fatalf("重试成功状态错误: 成功=%d 重试=%d 错误=%d", successes, retries, errors)
					}
				} else {
					if successes != 0 || errors == 0 {
						t.Errorf("失败流状态错误: 成功=%d 错误=%d", successes, errors)
					}
					if got := store.GetStats().LastCallSpeedTokPerSec; got != 37 {
						t.Errorf("失败覆盖旧速度: %d", got)
					}
					if mode == "retry-missing" && retries != 1 {
						t.Errorf("重试事件数=%d", retries)
					}
				}
			})
		}
	}
}
