package agent

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/lloyd/claude-code/bash-agent/go2/linenoise"
)

// ═══════════════════════════════════════════
// TermDisplay — 终端输出显示
// ═══════════════════════════════════════════

type TermDisplay struct {
	lastChar     byte      // 上次输出的最后一个字节
	prevThinking bool      // 上一个事件是否为 THINKING
	silent       bool      // stream-json 模式下抑制人类可读输出
	testWriter   io.Writer // 仅用于测试：非 nil 时走这里而非 linenoiseWrite
}

func NewTermDisplay() *TermDisplay {
	return &TermDisplay{lastChar: '\n'}
}

// SetWriter 设置输出目标（仅用于测试）
func (d *TermDisplay) SetWriter(w io.Writer) {
	d.testWriter = w
}

// writeRaw 发送字符串，不更新 lastChar（用于 ANSI 控制序列）。
func (d *TermDisplay) writeRaw(s string) {
	if s == "" {
		return
	}
	if d.testWriter != nil {
		fmt.Fprint(d.testWriter, s)
	} else {
		linenoise.LinenoiseWrite(s)
	}
}

// write 发送字符串并更新 lastChar。
func (d *TermDisplay) write(s string) {
	if s == "" {
		return
	}
	if d.testWriter != nil {
		fmt.Fprint(d.testWriter, s)
	} else {
		linenoise.LinenoiseWrite(s)
	}
	d.lastChar = s[len(s)-1]
}

// writef 格式化并写入
func (d *TermDisplay) writef(format string, args ...interface{}) {
	s := fmt.Sprintf(format, args...)
	d.write(s)
}

// EnsureNewline 确保光标在新行
func (d *TermDisplay) EnsureNewline() {
	if d.lastChar != '\n' && d.lastChar != 0 {
		d.write("\n")
	}
}

// SetLastChar 直接设置上次输出的最后一个字符
func (d *TermDisplay) SetLastChar(c byte) {
	d.lastChar = c
}

// HumanText 输出人类可读文本
func (d *TermDisplay) HumanText(s string) {
	if s == "" {
		return
	}
	d.write(s)
}

// SetSilent 设置静默模式（stream-json 时抑制人类可读输出）
func (d *TermDisplay) SetSilent(s bool) {
	d.silent = s
}

// SetTitle 设置终端标题 + iTerm2 progress indicator
func (d *TermDisplay) SetTitle(title string) {
	if d.silent {
		return
	}
	fmt.Fprint(os.Stderr, title)
}

func (d *TermDisplay) clearLineIfAtNewline() {
	if d.testWriter == nil && d.lastChar == '\n' {
		d.write("\r\033[K")
		d.lastChar = 0
	}
}

// ShowEvent 显示一个 Event
func (d *TermDisplay) ShowEvent(ev Event) {
	if d.silent {
		return
	}

	switch ev.Type {
	case EventText:
		d.clearLineIfAtNewline()
		if d.prevThinking && d.lastChar != '\n' {
			d.write("\n")
		}
		d.prevThinking = false
		if len(ev.Fields) > 1 && ev.Fields[1] != "" {
			d.write(ev.Fields[1])
		}

	case EventThinking:
		d.clearLineIfAtNewline()
		if len(ev.Fields) > 1 && ev.Fields[1] != "" {
			content := ev.Fields[1]
			/* 颜色码 + 内容 + 重置必须在一个 linenoiseWrite 调用内，
			 * 否则中间的 Show 重绘 prompt 时 \033[0m 会重置终端颜色 */
			linenoise.LinenoiseWrite("\033[90m" + content + "\033[0m")
			d.lastChar = content[len(content)-1]
		}
		d.prevThinking = true

	case EventToolCall:
		d.prevThinking = false
		d.EnsureNewline()
		summary := ""
		if len(ev.Fields) > 4 {
			summary = ev.Fields[4]
		} else if len(ev.Fields) > 1 {
			summary = ev.Fields[1]
		}
		d.writef("\033[33m[tool] %s\033[0m\n", summary)

	case EventToolResult:
		d.prevThinking = false
		text := ""
		if len(ev.Fields) > 3 {
			text = ev.Fields[3]
		}
		if text != "" {
			name := ""
			if len(ev.Fields) > 2 {
				name = ev.Fields[2]
			}
			if name == "Edit" {
				text = text + "\n"
			} else if name == "Read" || name == "Write" {
				lines := strings.SplitN(text, "\n", 2)
				text = lines[0] + "\n"
			} else {
				text = text + "\n"
			}
			d.write(text)
		}

	case EventUsage:

	case EventStop:
		d.prevThinking = false
		d.EnsureNewline()
		if len(ev.Fields) > 1 && ev.Fields[1] == "interrupted" {
			d.writef("\033[36mInterrupted.\033[0m\n")
		}

	case EventSubAgentResult:
		if d.testWriter == nil && d.lastChar == '\n' {
			d.write("\r\033[K")
		}
		d.EnsureNewline()
		// async task: Fields = ["ASYNC_TASK_RESULT", task_id, exit_code, output]
		if len(ev.Fields) >= 1 && ev.Fields[0] == "ASYNC_TASK_RESULT" {
			taskID := ev.Fields[1]
			exitCode := ev.Fields[2]
			output := ""
			if len(ev.Fields) > 3 {
				output = ev.Fields[3]
			}
			color := "31"
			if exitCode == "0" {
				color = "36"
			}
			d.writef("\033[%sm[bg-bash %s] exit_code=%s\033[0m\n", color, taskID, exitCode)
			if output != "" {
				if len(output) > 120 {
					d.writef("%s…\n", output[:120])
				} else {
					d.writef("%s\n", output)
				}
			}
			break
		}
		// sub-agent: Fields = ["AGENT_RESULT", session_id, status, in, out, thinking, text]
		if len(ev.Fields) >= 4 {
			sessionID := ev.Fields[1]
			status := ev.Fields[2]
			in := ev.Fields[3]
			out := ""
			thinking := ""
			text := ""
			if len(ev.Fields) > 4 {
				out = ev.Fields[4]
			}
			if len(ev.Fields) > 5 {
				thinking = ev.Fields[5]
			}
			if len(ev.Fields) > 6 {
				text = ev.Fields[6]
			}
			if status == "ok" {
				d.writef("\033[35m[sub-agent %s] completed (in=%s, out=%s)\033[0m\n", sessionID, in, out)
			} else {
				d.writef("\033[31m[sub-agent %s] failed\033[0m\n", sessionID)
			}
			if thinking != "" {
				if len(thinking) > 120 {
					d.writef("\033[90m%s…\033[0m\n", thinking[:120])
				} else {
					d.writef("\033[90m%s\033[0m\n", thinking)
				}
			}
			if text != "" {
				if len(text) > 120 {
					d.writef("%s…\n", text[:120])
				} else {
					d.writef("%s\n", text)
				}
			}
		}

	case EventError:
		d.EnsureNewline()
		if len(ev.Fields) > 1 {
			d.writef("\033[31mError: %s\033[0m\n", ev.Fields[1])
		}

	case EventContextUpdate:
		d.EnsureNewline()
		info := ""
		if len(ev.Fields) > 2 {
			info = ev.Fields[2]
		}
		d.writef("\033[36mContext compacted (%s).\033[0m\n", info)

	case EventUserMessage:
		content := ""
		if len(ev.Fields) > 1 {
			content = ev.Fields[1]
		}
		if content != "" {
			d.EnsureNewline()
			d.writef("\033[33m> %s\033[0m\n", content)
		}

	case EventUserNotify:
		text := ""
		if len(ev.Fields) > 1 {
			text = ev.Fields[1]
		}
		d.EnsureNewline()
		d.writef("\033[33m[user inject] %s\033[0m\n", text)
	}
}
