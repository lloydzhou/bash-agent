package agent

import (
	"fmt"
	"io"
	"os"
	"strings"
)

// ═══════════════════════════════════════════
// TermDisplay — 终端输出显示
// ═══════════════════════════════════════════

type TermDisplay struct {
	writer         io.Writer // 输出目标（默认 os.Stdout）
	lastChar       byte      // 上次输出的最后一个字符
	prevThinking   bool      // 上一个事件是否为 THINKING
	titleFormatter func(model string) string
}

func NewTermDisplay() *TermDisplay {
	return &TermDisplay{
		writer: os.Stdout,
	}
}

// SetWriter 设置输出目标
func (d *TermDisplay) SetWriter(w io.Writer) {
	d.writer = w
}

// SetTitleFormatter 设置标题格式化函数
func (d *TermDisplay) SetTitleFormatter(fn func(model string) string) {
	d.titleFormatter = fn
}

// EnsureNewline 确保光标在新行
func (d *TermDisplay) EnsureNewline() {
	if d.lastChar != '\n' && d.lastChar != 0 {
		fmt.Fprintln(d.writer)
		d.lastChar = '\n'
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
	fmt.Fprint(d.writer, s)
	if strings.HasSuffix(s, "\n") {
		d.lastChar = '\n'
	} else {
		d.lastChar = s[len(s)-1]
	}
}

// SetTitle 设置终端标题
func (d *TermDisplay) SetTitle(title string) {
	if d.titleFormatter != nil {
		title = d.titleFormatter(title)
	}
	// OSC 终端标题
	fmt.Fprintf(d.writer, "\033]0;%s\007", title)
}

// ShowEvent 显示一个 Event
func (d *TermDisplay) ShowEvent(ev Event) {
	switch ev.Type {
	case EventText:
		// thinking → text 转换时补换行
		if d.prevThinking && d.lastChar != '\n' {
			fmt.Fprintln(d.writer)
			d.lastChar = '\n'
		}
		d.prevThinking = false
		if len(ev.Fields) > 1 && ev.Fields[1] != "" {
			d.HumanText(ev.Fields[1])
		}

	case EventThinking:
		if len(ev.Fields) > 1 && ev.Fields[1] != "" {
			fmt.Fprintf(d.writer, "\033[90m%s\033[0m", ev.Fields[1])
			if strings.HasSuffix(ev.Fields[1], "\n") {
				d.lastChar = '\n'
			} else {
				d.lastChar = ev.Fields[1][len(ev.Fields[1])-1]
			}
		}
		d.prevThinking = true

	case EventToolCall:
		d.prevThinking = false
		d.EnsureNewline()
		summary := ""
		if len(ev.Fields) > 4 {
			// Fields: ["TOOL_CALL", name, id, inputJSON, callSummary]
			summary = ev.Fields[4]
		} else if len(ev.Fields) > 1 {
			summary = ev.Fields[1]
		}
		fmt.Fprintf(d.writer, "\033[33m[tool] %s\033[0m\n", summary)
		d.lastChar = '\n'

	case EventToolResult:
		d.prevThinking = false
		text := ""
		if len(ev.Fields) > 3 {
			text = ev.Fields[3] // result content
		}
		if text != "" {
			name := ""
			if len(ev.Fields) > 2 {
				name = ev.Fields[2]
			}
			if name == "Edit" {
				// Edit: 全文 + 换行
				text = text + "\n"
			} else if name == "Read" || name == "Write" {
				// Read/Write: 只显示第一行摘要 + 换行
				lines := strings.SplitN(text, "\n", 2)
				text = lines[0] + "\n"
			} else {
				// 其他工具：全文 + 换行（与 bash 版一致）
				text = text + "\n"
			}
			d.HumanText(text)
		}

	case EventUsage:
		// usage 不需要终端显示

	case EventStop:
		d.prevThinking = false
		d.EnsureNewline()
		// 与 bash 版 display_message STOP 分支对齐：interrupted 时打印提示
		if len(ev.Fields) > 1 && ev.Fields[1] == "interrupted" {
			fmt.Printf("\033[36mInterrupted.\033[0m\n")
			d.lastChar = '\n'
		}

	case EventSubAgentResult:
		// Fields: ["SUB_AGENT_RESULT", sessionID, status, in, out, thinking, text]
		d.EnsureNewline()
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
				fmt.Fprintf(d.writer, "\033[35m[sub-agent %s] completed (in=%s, out=%s)\033[0m\n", sessionID, in, out)
			} else {
				fmt.Fprintf(d.writer, "\033[31m[sub-agent %s] failed\033[0m\n", sessionID)
			}
			if thinking != "" {
				if len(thinking) > 120 {
					fmt.Fprintf(d.writer, "\033[90m%s…\033[0m\n", thinking[:120])
				} else {
					fmt.Fprintf(d.writer, "\033[90m%s\033[0m\n", thinking)
				}
			}
			if text != "" {
				if len(text) > 120 {
					fmt.Fprintf(d.writer, "%s…\n", text[:120])
				} else {
					fmt.Fprintf(d.writer, "%s\n", text)
				}
			}
		}
		d.lastChar = '\n'

	case EventError:
		d.EnsureNewline()
		if len(ev.Fields) > 1 {
			fmt.Fprintf(d.writer, "\033[31mError: %s\033[0m\n", ev.Fields[1])
		}
		d.lastChar = '\n'

	case EventContextUpdate:
		d.EnsureNewline()
		info := ""
		if len(ev.Fields) > 2 {
			info = ev.Fields[2]
		}
		fmt.Fprintf(d.writer, "\033[36mContext compacted (%s).\033[0m\n", info)
		d.lastChar = '\n'

	case EventUserMessage:
		content := ""
		if len(ev.Fields) > 1 {
			content = ev.Fields[1]
		}
		if content != "" {
			d.EnsureNewline()
			fmt.Fprintf(d.writer, "\033[33m> %s\033[0m\n", content)
			d.lastChar = '\n'
		}
	}
}
