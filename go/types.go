// Package agent — bash-agent Go 版本，严格对齐 bash 6 类前缀
//
// 6 类 = 6 个文件：
//
//	util.go      — util_* (23) 包级工具函数
//	store.go     — store_* (27, 含 fork) SessionStore interface + FileStore
//	transport.go — llm_* (3)   Transport interface + HTTP
//	tools.go     — tool_* (20)  ToolDispatcher
//	display.go   — display_* (4) Display interface
//	agent.go     — agent_* (8)  Agent struct，编排层
package agent

import (
	"context"
)

// ─── Config ───

// Config 包含所有用户可配置选项（对应 bash 全局变量）
type Config struct {
	Provider           string   // claude | openai
	Model              string   // 模型名
	APIKey             string   // API 密钥
	BaseURL            string   // API 基础 URL
	MaxTokens          int      // 最大输出 token
	MaxTurns           int      // 最大轮次
	MaxContextTokens   int      // 上下文窗口上限
	ToolTimeoutSecs    int      // 工具超时（秒）
	OutputFormat       string   // human | stream-json
	Verbose            bool     // 调试输出
	Interactive        bool     // 交互模式
	ToolResultMaxBytes int      // 工具结果最大字节数
	Thinking           string   // thinking 模式: adaptive|enabled|disabled
	Effort             string   // thinking effort: low|medium|high|xhigh|max
	SkillNames         []string // 加载的 skill 列表
	JinaAPIKey         string   // Jina API key（WebSearch/WebFetch）

	// DP Compact 配置
	DPBaselineE      int     // baseline for E calculation
	DPEFixed         int     // fixed E override
	DPFixed          float64 // fixed L override
	DPVPrefix        int     // fixed prefix tokens (system prompt + tools + summary)
	DPSummaryLen     float64 // fixed summary length tokens
	DPPInput         float64 // uncached input price $/MTok
	DPPCache         float64 // cached input price $/MTok
	DPPOut           float64 // output price $/MTok
	DPMinKeepRatio   float64 // minimum fraction of messages to retain
	DPRetention      float64 // single-step summary retention rate
	DPBeta           float64 // info loss penalty coefficient
	DPQualityPenalty float64 // quality decay penalty coefficient (default 0.2)
}

// DefaultConfig 返回默认配置
func DefaultConfig() Config {
	return Config{
		Provider:           "claude",
		Model:              "",
		MaxTokens:          4096,
		MaxTurns:           40,
		MaxContextTokens:   200000,
		ToolTimeoutSecs:    600,
		OutputFormat:       "human",
		Verbose:            false,
		Interactive:        false,
		ToolResultMaxBytes: 100000,
		Thinking:           "adaptive",
		Effort:             "high",
	}
}

// ─── 核心消息类型 ───

// Event 表示 agent 内部事件（替代 bash 的 REPLY_MESSAGE 数组）
// 用 channel 传递，取代 FIFO + RESP 协议
type Event struct {
	Type    EventType   // 事件类型
	Fields  []string    // 原始字段（兼容 bash 的 REPLY_MESSAGE）
	Payload interface{} // 类型化载荷（可选）
}

// EventType 事件类型枚举
type EventType int

const (
	EventText           EventType = iota // TEXT
	EventThinking                        // THINKING
	EventToolCall                        // TOOL_CALL
	EventToolResult                      // TOOL_RESULT
	EventUsage                           // USAGE
	EventStop                            // STOP
	EventContextUpdate                   // CONTEXT_UPDATE
	EventError                           // ERROR
	EventRetry                           // RETRY
	EventUserMessage                     // USER_INPUT (主循环)
	EventAgentResult                     // AGENT_RESULT (子 agent 返回)
	EventSubAgentResult                  // SUB_AGENT_RESULT (replay 用)
)

// Usage 记录 token 使用量
type Usage struct {
	InputTokens  int
	OutputTokens int
	CacheRead    int // CacheReadInputTokens
	CacheWrite   int // CacheCreationInputTokens
	Cost         float64
}

// ToolCallInfo 表示一个工具调用
type ToolCallInfo struct {
	Name   string
	ID     string
	Input  string
	Params map[string]string // 解析后的参数
}

// ToolResultInfo 表示工具执行结果
type ToolResultInfo struct {
	ToolID     string
	ToolName   string
	Output     string
	ConvOutput string
}

// Stats 会话统计数据
type Stats struct {
	TurnCount        int     `json:"current_turn_count"`          // user turn count
	InputTokens      int     `json:"total_input_tokens"`          // cumulative input
	OutputTokens     int     `json:"total_output_tokens"`         // cumulative output
	CacheWrite       int     `json:"total_cache_creation_tokens"` // cumulative cache write
	CacheRead        int     `json:"total_cache_read_tokens"`     // cumulative cache read
	TotalCost        float64 `json:"total_cost"`                  // cumulative cost
	TotalRequests    int     `json:"agent_request_count"`         // total LLM requests
	TotalCompact     int     `json:"compact_request_count"`       // number of compactions
	ContextTokens    int     `json:"current_context_tokens"`      // current context size
	SubAgentRequests int     `json:"sub_agent_request_count"`     // sub-agent requests
	LastUpdated      string  `json:"last_updated"`                // ISO 8601 timestamp
}

// SessionRow session 列表行
type SessionRow struct {
	Name     string
	Modified string
	Preview  string
}

// ─── Interface 定义（4 个核心接口） ───

// SessionStore 会话存储接口（store_* 27 个方法）
type SessionStore interface {
	// Session lifecycle
	Init(sessionID string) error
	Fork(parentDir, childDir string) error
	GetDir() string
	GetLatestDir() (string, error)
	ResolveContinue() (string, error)
	SessionID() string

	// Events
	AppendEvent(jsonLine string) error
	GetRecentEvents(maxUserTurns int) []string

	// Conversation
	AddUserMessage(content string) error
	AddAssistantMessage(text, thinking string, calls []ToolCallInfo) error
	AddToolResults(results []ToolResultInfo) error
	GetMessages() (string, error)
	ConvLineCount() (int, error)
	ConvHeadTo(n int) (string, error)
	ConvTrimTail(n int) error
	ConvUserTurnCount() (int, error)
	CompactDPDecision(cfg Config) (int, error)
	ConvTurnKeep(ratio float64) (int, error)

	// Summary
	SetSummary(text string) error
	GetSummary() (string, error)

	// Stats
	UpdateStats(usage Usage, model string) error
	GetStats() Stats
	FormatTitle(model string) string
	SetContextTokens(n int)
	IncrementTurn() error
	SetTurnCount(n int) error
	IncrementCompact() error
	UpdateCompactStats(usage Usage) error

	// Plan
	PlanPath() string
	PlanDraftPath() string
	GetPlan() (string, error)
	SetPlan(text string) error
	GetPlanDraft() (string, error)
	SetPlanDraft(text string) error
	ClearPlanDraft() error
	PlanDraftIsEmpty() (bool, error)
	PlanConfirm() error
	PlanClear() error

	// Sub-agent
	SubSendResult(sessionID, status, outputFile string, output string) error
	GetSubAgentStats(sessionID string) (Stats, error)
	GetSubAgentResult(sessionID string) (thinking, text string, err error)
	UpdateSubAgentStats(inputTokens, outputTokens, cacheRead, cacheWrite, requests int) error

	// Session list
	ListSessionRows() []SessionRow
}

// Transport LLM 传输接口（llm_* 3 个方法）
type Transport interface {
	// Call 发起流式 LLM 调用，通过 channel 返回 Event
	Call(ctx context.Context, messages, systemPrompt, toolDefs string, maxTokens int, thinking string) (<-chan Event, error)
	// SummaryCall 压缩用的摘要调用
	SummaryCall(ctx context.Context, droppedMessages string) (string, Usage, error)
}

// Display 输出显示接口（display_* 4 个方法）
type Display interface {
	EnsureNewline()
	HumanText(s string)
	ShowEvent(ev Event)
	SetTitle(title string)
}

// ToolExecutor 工具执行器接口（供 ToolDispatcher 回调）
type ToolExecutor interface {
	// ExecuteTool 执行工具并返回输出
	ExecuteTool(ctx context.Context, name string, params map[string]string) (string, error)
}

// ─── 其他辅助类型 ───
