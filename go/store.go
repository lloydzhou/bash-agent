package agent

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// ═══════════════════════════════════════════
// FileStore — 基于 JSONL/TXT 文件的会话存储
// ═══════════════════════════════════════════

type FileStore struct {
	mu        sync.Mutex
	home      string // BASH_AGENT_HOME 或 $HOME
	cwd       string // 当前工作目录
	sessionID string

	// 文件路径（Init 后填充）
	convFile      string
	eventFile     string
	summaryFile   string
	planFile      string
	planDraftFile string
	statsFile     string

	// 内存缓存 stats（避免频繁 AWK）
	stats Stats
}

// ─── Stats ───

func (s *FileStore) GetStats() Stats {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.stats
}

func (s *FileStore) UpdateStats(usage Usage, model string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// TurnCount 不在此处递增——只在用户输入时由 IncrementTurn 处理
	s.stats.TotalRequests++
	s.stats.InputTokens += usage.InputTokens
	s.stats.OutputTokens += usage.OutputTokens
	s.stats.CacheWrite += usage.CacheWrite
	s.stats.CacheRead += usage.CacheRead
	s.stats.TotalCost += usage.Cost

	return s.flushStats()
}

func (s *FileStore) IncrementTurn() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stats.TurnCount++
	return s.flushStats()
}

func (s *FileStore) SetTurnCount(n int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stats.TurnCount = n
	return s.flushStats()
}

// UpdateSubAgentStats 累加子 agent 的 token 用量到父 agent（与 bash 版 agent_handle_sub_result 中 store_stats_update 一致）
func (s *FileStore) UpdateSubAgentStats(inputTokens, outputTokens, cacheRead, cacheWrite, requests int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stats.InputTokens += inputTokens
	s.stats.OutputTokens += outputTokens
	s.stats.CacheRead += cacheRead
	s.stats.CacheWrite += cacheWrite
	s.stats.TotalRequests += requests
	return s.flushStats()
}

func (s *FileStore) IncrementCompact() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stats.TotalCompact++
	return s.flushStats()
}

func (s *FileStore) SetContextTokens(n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stats.ContextTokens = n
	s.flushStats()
}

func (s *FileStore) loadStats() {
	data, err := os.ReadFile(s.statsFile)
	if err != nil {
		s.stats = Stats{}
		return
	}
	json.Unmarshal(data, &s.stats)
}

func (s *FileStore) flushStats() error {
	// 必须用单行 JSON（Marshal），因为 bash 的 AWK stats.awk _read_file 只读第一行
	// 用正则匹配字段。多行格式（MarshalIndent）会导致 bash 解析时所有字段归零。
	data, _ := json.Marshal(s.stats)
	return os.WriteFile(s.statsFile, data, 0644)
}

func NewFileStore(home, cwd string) *FileStore {
	return &FileStore{home: home, cwd: cwd}
}

// ─── Session lifecycle ───

func (s *FileStore) Init(sessionID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if sessionID == "" {
		sessionID = UtilNewSessionID()
	}
	s.sessionID = sessionID

	dir := filepath.Join(s.GetDir(), sessionID)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("create session dir: %w", err)
	}

	s.convFile = filepath.Join(dir, "conversation.jsonl")
	s.eventFile = filepath.Join(dir, "events.jsonl")
	s.summaryFile = filepath.Join(dir, "summary.txt")
	s.planFile = filepath.Join(dir, "plan.md")
	s.planDraftFile = filepath.Join(dir, "plan.draft")
	s.statsFile = filepath.Join(dir, "stats.json")

	// 确保文件存在（不截断已有内容）
	newSession := false
	if fi, err := os.Stat(s.eventFile); err != nil || fi.Size() == 0 {
		newSession = true
	}
	for _, f := range []string{s.convFile, s.eventFile, s.summaryFile, s.planFile, s.planDraftFile} {
		file, err := os.OpenFile(f, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		if err != nil {
			return fmt.Errorf("touch %s: %w", f, err)
		}
		file.Close()
	}
	if s.statsFile != "" {
		if _, err := os.Stat(s.statsFile); os.IsNotExist(err) {
			os.WriteFile(s.statsFile, []byte("{}"), 0644)
		}
	}

	if newSession {
		ev := fmt.Sprintf(`{"type":"session_start","session_id":"%s"}`, UtilJSONEscape(sessionID))
		_, _ = os.OpenFile(s.eventFile, os.O_CREATE|os.O_WRONLY, 0644)
		f, err := os.OpenFile(s.eventFile, os.O_WRONLY|os.O_APPEND, 0644)
		if err == nil {
			fmt.Fprintln(f, ev)
			f.Close()
		}
	}

	// 加载已有 stats
	s.loadStats()
	return nil
}

func (s *FileStore) Fork(parentDir, childDir string) error {
	os.MkdirAll(childDir, 0755)
	for _, name := range []string{"conversation.jsonl", "summary.txt", "plan.md"} {
		src := filepath.Join(parentDir, name)
		dst := filepath.Join(childDir, name)
		data, err := os.ReadFile(src)
		if err != nil {
			continue
		}
		os.WriteFile(dst, data, 0644)
	}
	return nil
}

func (s *FileStore) GetDir() string {
	cwd, _ := filepath.Abs(s.cwd)
	projectKey := pathToProjectKey(cwd)
	base := s.home
	if base == "" {
		base, _ = os.UserHomeDir()
	}
	return filepath.Join(base, ".bash-agent", "projects", projectKey)
}

func (s *FileStore) GetLatestDir() (string, error) {
	projectDir := s.GetDir()
	entries, err := os.ReadDir(projectDir)
	if err != nil {
		return "", fmt.Errorf("no sessions found")
	}
	var latest string
	var latestTs int64
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		fi, err := e.Info()
		if err != nil {
			continue
		}
		if fi.ModTime().Unix() > latestTs {
			latestTs = fi.ModTime().Unix()
			latest = e.Name()
		}
	}
	if latest == "" {
		return "", fmt.Errorf("no sessions found")
	}
	return latest, nil
}

func (s *FileStore) ResolveContinue() (string, error) {
	id, err := s.GetLatestDir()
	if err != nil {
		return UtilNewSessionID(), nil
	}
	return id, nil
}

func (s *FileStore) SessionID() string {
	return s.sessionID
}

// ─── Events ───

func (s *FileStore) AppendEvent(jsonLine string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.eventFile == "" {
		return nil
	}
	f, err := os.OpenFile(s.eventFile, os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return err
	}
	fmt.Fprintln(f, jsonLine)
	return f.Close()
}

// GetRecentEvents 返回最近 maxUserTurns 个用户轮次的事件行
// 逻辑与 bash 版 interactive_mode 一致：找最后 N 个 "type":"user_input" 行，
// 从第一个匹配行开始返回全部事件
func (s *FileStore) GetRecentEvents(maxUserTurns int) []string {
	s.mu.Lock()
	file := s.eventFile
	s.mu.Unlock()
	if file == "" {
		return nil
	}

	data, err := os.ReadFile(file)
	if err != nil || len(data) == 0 {
		return nil
	}

	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")

	// 找所有包含 "type":"user_input" 的行号
	var userInputLines []int
	for i, line := range lines {
		if strings.Contains(line, `"type":"user_input"`) || strings.Contains(line, `"type":"user_input"`) {
			userInputLines = append(userInputLines, i)
		}
	}

	// 没有用户输入事件 → 不 replay
	if len(userInputLines) == 0 {
		return nil
	}

	// 取最后 maxUserTurns 个 user_input 的第一个
	start := len(userInputLines) - maxUserTurns
	if start < 0 {
		start = 0
	}
	fromLine := userInputLines[start]

	return lines[fromLine:]
}

// ─── Conversation ───

func (s *FileStore) AddUserMessage(content string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	escaped := UtilJSONEscape(content)
	line := fmt.Sprintf(`{"role":"user","content":"%s"}`, escaped)
	return s.appendLine(s.convFile, line)
}

func (s *FileStore) AddAssistantMessage(text, thinking string, calls []ToolCallInfo) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	content := UtilBuildAssistantJSON(text, thinking, calls)
	line := fmt.Sprintf(`{"role":"assistant","content":%s}`, content)
	return s.appendLine(s.convFile, line)
}

func (s *FileStore) AddToolResults(results []ToolResultInfo) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var buf strings.Builder
	buf.WriteString("[")
	for i, r := range results {
		if i > 0 {
			buf.WriteString(",")
		}
		buf.WriteString(UtilBuildToolResultJSON(r.ToolID, r.Output, "tool_result"))
	}
	buf.WriteString("]")
	line := fmt.Sprintf(`{"role":"user","content":%s}`, buf.String())
	return s.appendLine(s.convFile, line)
}

func (s *FileStore) GetMessages() (string, error) {
	data, err := os.ReadFile(s.convFile)
	if err != nil {
		return "[]", nil
	}
	lines := splitNonEmpty(string(data))
	return "[" + strings.Join(lines, ",") + "]", nil
}

func (s *FileStore) ConvLineCount() (int, error) {
	data, err := os.ReadFile(s.convFile)
	if err != nil {
		return 0, nil
	}
	return len(splitNonEmpty(string(data))), nil
}

func (s *FileStore) ConvHeadTo(n int) (string, error) {
	data, err := os.ReadFile(s.convFile)
	if err != nil {
		return "", err
	}
	lines := splitNonEmpty(string(data))
	if n > len(lines) {
		n = len(lines)
	}
	return strings.Join(lines[:n], "\n") + "\n", nil
}

func (s *FileStore) ConvTrimTail(n int) error {
	data, err := os.ReadFile(s.convFile)
	if err != nil {
		return err
	}
	lines := splitNonEmpty(string(data))
	if n > len(lines) {
		n = len(lines)
	}
	keep := lines[len(lines)-n:]
	return os.WriteFile(s.convFile, []byte(strings.Join(keep, "\n")+"\n"), 0644)
}

func (s *FileStore) ConvUserTurnCount() (int, error) {
	data, err := os.ReadFile(s.convFile)
	if err != nil {
		return 0, nil
	}
	count := 0
	for _, line := range splitNonEmpty(string(data)) {
		if strings.Contains(line, `"role":"user"`) && !strings.Contains(line, `"content":[`) {
			count++
		}
	}
	return count, nil
}

// ─── Summary ───

func (s *FileStore) GetSummary() (string, error) {
	return UtilReadOptional(s.summaryFile)
}

func (s *FileStore) SetSummary(text string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return os.WriteFile(s.summaryFile, []byte(text+"\n"), 0644)
}

// ─── Plan ───

func (s *FileStore) GetPlan() (string, error) {
	return UtilReadOptional(s.planFile)
}
func (s *FileStore) PlanPath() string {
	return s.planFile
}
func (s *FileStore) PlanDraftPath() string {
	return s.planDraftFile
}

func (s *FileStore) SetPlan(text string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return os.WriteFile(s.planFile, []byte(text+"\n"), 0644)
}

func (s *FileStore) GetPlanDraft() (string, error) {
	return UtilReadOptional(s.planDraftFile)
}

func (s *FileStore) SetPlanDraft(text string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return os.WriteFile(s.planDraftFile, []byte(text+"\n"), 0644)
}

func (s *FileStore) ClearPlanDraft() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return os.WriteFile(s.planDraftFile, []byte(""), 0644)
}

func (s *FileStore) PlanDraftIsEmpty() (bool, error) {
	data, err := os.ReadFile(s.planDraftFile)
	if err != nil {
		return true, err
	}
	return strings.TrimSpace(string(data)) == "", nil
}

// ─── Compact: DP 最优决策（移植 compact_dp.awk）───

// CompactDPDecision 计算 DP 最优保留行数。
// 返回 0 表示不压缩。
func (s *FileStore) CompactDPDecision(cfg Config) (int, error) {
	data, err := os.ReadFile(s.convFile)
	if err != nil {
		return 0, err
	}
	lines := splitNonEmpty(string(data))
	n := len(lines)
	if n == 0 {
		return 0, nil
	}

	// 每行大小（token ≈ (字节数+3)/4 + 1）
	sizes := make([]int, n)
	roles := make([]string, n)
	totalTokens := 0
	for i, line := range lines {
		sz := int((len(line)+3)/4) + 1
		sizes[i] = sz
		totalTokens += sz
		if strings.Contains(line, `"role":"user"`) && !strings.Contains(line, `"content":[`) {
			roles[i] = "user"
		} else {
			roles[i] = "other"
		}
	}

	// E: expected remaining user-input rounds
	baselineE := cfg.DPBaselineE
	if baselineE == 0 {
		baselineE = 8
	}
	eFixed := cfg.DPEFixed
	remaining := baselineE - s.stats.TurnCount
	floor := baselineE / 2
	if floor < 2 {
		floor = 2
	}
	var E float64
	if eFixed > 0 {
		E = float64(eFixed)
	} else if baselineE > 0 {
		if float64(remaining) > float64(floor) {
			E = float64(remaining)
		} else {
			E = float64(floor)
		}
	} else {
		E = 2
	}

	// L: avg LLM calls per user input
	L := 5.0
	if s.stats.TurnCount > 0 && s.stats.TotalRequests > 0 {
		L = float64(s.stats.TotalRequests) / float64(s.stats.TurnCount)
	}
	if cfg.DPFixed > 0 {
		L = float64(cfg.DPFixed)
	}
	if L < 1 {
		L = 1
	}

	// avg input tokens per LLM request
	avg := 4000.0
	if s.stats.TurnCount > 0 && s.stats.InputTokens > 0 {
		avg = float64(s.stats.InputTokens) / float64(s.stats.TotalRequests)
	}

	// R = total expected remaining LLM calls
	R := E * L

	// cumulative retention
	c := s.stats.TotalCompact
	r := cfg.DPRetention
	if r == 0 {
		r = 0.85
	}
	rT := 1.0
	for i := 0; i <= c; i++ {
		rT *= r
	}
	if rT < 0.37 {
		rT = 0.37
	}

	V := float64(cfg.DPVPrefix) // fixed prefix tokens
	S := float64(cfg.DPSummaryLen)
	if S == 0 {
		S = 400
	}
	pInput := cfg.DPPInput
	if pInput == 0 {
		pInput = 3.0
	}
	pCache := cfg.DPPCache
	if pCache == 0 {
		pCache = 0.3
	}
	pOut := cfg.DPPOut
	if pOut == 0 {
		pOut = 15.0
	}
	minRatio := cfg.DPMinKeepRatio
	if minRatio == 0 {
		minRatio = 0.12
	}
	beta := cfg.DPBeta
	if beta == 0 {
		beta = 0.15
	}
	lInstr := 70.0

	NRemain := R * avg
	infoLoss := beta * (1.0 - rT) * NRemain * pInput / 1e6

	minKeep := int(float64(n)*minRatio + 0.5)
	if minKeep < 3 {
		minKeep = 3
	}
	if minKeep > n {
		minKeep = n
	}

	bestK := 0
	bestBenefit := -1e18

	for k := minKeep; k <= n; k++ {
		K := 0
		for i := n - k; i < n; i++ {
			K += sizes[i]
		}
		H := totalTokens - K
		if H <= 0 {
			continue
		}

		savings := (R - 1) * pCache * float64(H) / 1e6
		cacheMiss := (S + float64(K)) * (pInput - pCache) / 1e6
		compactCost := (pCache*(V+float64(H)) + pInput*lInstr + pOut*S) / 1e6
		benefit := savings - cacheMiss - compactCost - infoLoss

		if benefit > bestBenefit {
			bestBenefit = benefit
			bestK = k
		}
	}

	if bestBenefit > 0 {
		// 对齐到 user message 边界
		adj := bestK
		cut := n - adj
		for cut > 0 && roles[cut] != "user" {
			cut--
		}
		adj = n - cut
		if adj < 1 {
			adj = 1
		}
		return adj, nil
	}
	return 0, nil
}

// ─── TurnKeep: 按 ratio 保留最近的 turn 边界行 ───

func (s *FileStore) ConvTurnKeep(ratio float64) (int, error) {
	data, err := os.ReadFile(s.convFile)
	if err != nil {
		return 0, err
	}
	lines := splitNonEmpty(string(data))
	n := len(lines)
	if n == 0 {
		return 0, nil
	}

	// 找所有 user 行位置
	var userIdx []int
	for i, line := range lines {
		if strings.Contains(line, `"role":"user"`) && !strings.Contains(line, `"content":[`) {
			userIdx = append(userIdx, i)
		}
	}
	if len(userIdx) == 0 {
		return 0, nil
	}

	// 从尾部往前数，保留 ratio 比例的 turns
	keepTurns := int(float64(len(userIdx))*ratio + 0.5)
	if keepTurns < 1 {
		keepTurns = 1
	}
	startTurn := len(userIdx) - keepTurns
	if startTurn < 0 {
		startTurn = 0
	}
	cutLine := userIdx[startTurn]
	kept := n - cutLine

	return kept, nil
}

// ─── FormatTitle: 终端标题 ───

func (s *FileStore) FormatTitle(model string) string {
	st := s.stats
	cacheTotal := st.InputTokens + st.CacheRead
	cachePct := "—"
	if cacheTotal > 0 && st.CacheRead > 0 {
		cachePct = fmt.Sprintf("%.0f%%", float64(st.CacheRead)/float64(cacheTotal)*100)
	}
	return fmt.Sprintf("%s T:%s R:%d I:%s(%s) O:%s C:%s",
		model,
		fmtInt(st.TurnCount),
		st.TotalRequests,
		fmtInt(cacheTotal),
		cachePct,
		fmtInt(st.OutputTokens),
		fmtInt(st.ContextTokens))
}

// fmtInt 整数千分位格式化
func fmtInt(n int) string {
	s := fmt.Sprintf("%d", n)
	if len(s) <= 3 {
		return s
	}
	// 从右往左每3位加逗号
	var result string
	for i := len(s) - 1; i >= 0; i-- {
		if (len(s)-1-i)%3 == 0 && i != len(s)-1 {
			result = "," + result
		}
		result = string(s[i]) + result
	}
	return result
}

// ─── SubSendResult: 子 agent 结果写回 ───

func (s *FileStore) SubSendResult(sessionID, status, outputFile string, output string) error {
	result := map[string]string{
		"session_id": sessionID,
		"status":     status,
		"output":     output,
	}
	data, _ := json.Marshal(result)
	return os.WriteFile(outputFile, data, 0644)
}

// ─── GetSubAgentStats: 读取子 agent 的 stats ───

func (s *FileStore) GetSubAgentStats(sessionID string) (Stats, error) {
	projectDir := filepath.Dir(filepath.Dir(s.convFile))
	statsFile := filepath.Join(projectDir, sessionID, "stats.json")
	data, err := os.ReadFile(statsFile)
	if err != nil {
		return Stats{}, err
	}
	var stats Stats
	if err := json.Unmarshal(data, &stats); err != nil {
		return Stats{}, err
	}
	return stats, nil
}

// ─── GetSubAgentResult: 从子 agent conversation.jsonl 提取最后一条 assistant 消息的 thinking 和 text

func (s *FileStore) GetSubAgentResult(sessionID string) (thinking, text string, err error) {
	projectDir := filepath.Dir(filepath.Dir(s.convFile))
	convFile := filepath.Join(projectDir, sessionID, "conversation.jsonl")
	data, err := os.ReadFile(convFile)
	if err != nil {
		return "", "", err
	}

	// 找最后一条 assistant 行
	lines := strings.Split(string(data), "\n")
	var lastAssistant string
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		if strings.Contains(line, `"role":"assistant"`) {
			lastAssistant = line
			break
		}
	}
	if lastAssistant == "" {
		return "", "", nil
	}

	// 解析 content 数组，提取 thinking 和 text
	// 格式: {"role":"assistant","content":[{"type":"thinking","thinking":"..."},{"type":"text","text":"..."},...]}
	contentIdx := strings.Index(lastAssistant, `"content":`)
	if contentIdx < 0 {
		return "", "", nil
	}
	// content 值从这里开始
	braceStart := strings.Index(lastAssistant[contentIdx:], "[")
	if braceStart < 0 {
		return "", "", nil
	}
	braceStart += contentIdx

	// 找匹配的 ]
	depth := 0
	braceEnd := -1
	for i := braceStart; i < len(lastAssistant); i++ {
		switch lastAssistant[i] {
		case '[':
			depth++
		case ']':
			depth--
			if depth == 0 {
				braceEnd = i
				goto found
			}
		}
	}
found:
	if braceEnd < 0 {
		return "", "", nil
	}

	contentJSON := lastAssistant[braceStart : braceEnd+1]
	// 逐个提取顶层对象
	// 简单策略：用正则或手动遍历找 "type":"thinking" 和 "type":"text" 块
	extractField := func(block, key string) string {
		pattern := `"` + key + `":"`
		idx := strings.Index(block, pattern)
		if idx < 0 {
			return ""
		}
		start := idx + len(pattern)
		// 找到结尾的 "（处理转义）
		var sb strings.Builder
		for i := start; i < len(block); i++ {
			if block[i] == '\\' && i+1 < len(block) {
				// 转义字符
				sb.WriteByte(block[i+1])
				i++
				continue
			}
			if block[i] == '"' {
				break
			}
			sb.WriteByte(block[i])
		}
		return sb.String()
	}

	// 按顶层 { } 分割
	objStart := -1
	depth = 0
	for i := 0; i < len(contentJSON); i++ {
		switch contentJSON[i] {
		case '{':
			if depth == 0 {
				objStart = i
			}
			depth++
		case '}':
			depth--
			if depth == 0 && objStart >= 0 {
				obj := contentJSON[objStart : i+1]
				typ := extractField(obj, "type")
				switch typ {
				case "thinking":
					thinking = extractField(obj, "thinking")
				case "text":
					text = extractField(obj, "text")
				}
				objStart = -1
			}
		}
	}

	return thinking, text, nil
}

func (s *FileStore) PlanConfirm() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	draft, err := os.ReadFile(s.planDraftFile)
	if err != nil || len(strings.TrimSpace(string(draft))) == 0 {
		return fmt.Errorf("plan draft is empty")
	}
	os.WriteFile(s.planFile, draft, 0644)
	os.WriteFile(s.planDraftFile, []byte(""), 0644)
	return nil
}

// ─── PlanClear ───

func (s *FileStore) PlanClear() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	os.WriteFile(s.planFile, []byte(""), 0644)
	return nil
}

// ═══════════════════════════════════════════
// 辅助函数
// ═══════════════════════════════════════════

func (s *FileStore) appendLine(file, line string) error {
	f, err := os.OpenFile(file, os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return err
	}
	fmt.Fprintln(f, line)
	return f.Close()
}

func splitNonEmpty(s string) []string {
	var result []string
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			result = append(result, line)
		}
	}
	return result
}

func pathToProjectKey(absPath string) string {
	// 把 /Users/foo/project → -Users-foo-project（与 bash 版一致）
	key := strings.ReplaceAll(absPath, "/", "-")
	key = strings.ReplaceAll(key, ":", "")
	// bash 版: 先去前导 /，再加前缀 -
	key = strings.TrimPrefix(key, "-")
	key = "-" + key
	if len(key) > 200 {
		key = key[:200]
	}
	return key
}

// ListSessionRows 返回所有 session 的行信息（与 bash 版 store_session_list_rows 一致）
func (s *FileStore) ListSessionRows() []SessionRow {
	dir := s.GetDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var rows []SessionRow
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		row := SessionRow{
			Name:     e.Name(),
			Modified: info.ModTime().Format("2006-01-02 15:04"),
		}
		// 从 summary.txt 取第一行非空内容作为 preview
		summaryFile := filepath.Join(dir, e.Name(), "summary.txt")
		if data, err := os.ReadFile(summaryFile); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				line = strings.TrimSpace(line)
				if line != "" {
					if len(line) > 60 {
						line = line[:57] + "..."
					}
					row.Preview = line
					break
				}
			}
		}
		rows = append(rows, row)
	}
	return rows
}

