package agent

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
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
	sessionDir    string // 会话基础目录

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
	s.stats.SubAgentRequests++
	return s.flushStats()
}

func (s *FileStore) IncrementCompact() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stats.TotalCompact++
	return s.flushStats()
}

func (s *FileStore) UpdateCompactStats(usage Usage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stats.TotalCompact++
	s.stats.InputTokens += usage.InputTokens
	s.stats.OutputTokens += usage.OutputTokens
	s.stats.CacheRead += usage.CacheRead
	s.stats.CacheWrite += usage.CacheWrite
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
	s.stats.LastUpdated = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	data, _ := json.Marshal(s.stats)
	return os.WriteFile(s.statsFile, data, 0644)
}

func NewFileStore(home, cwd string) *FileStore {
	return &FileStore{home: home, cwd: cwd}
}

func (s *FileStore) GetHomeDir() string { return s.home }
func (s *FileStore) GetCwd() string     { return s.cwd }

// ─── Session lifecycle ───

func (s *FileStore) Init(sessionID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if sessionID == "" {
		sessionID = UtilNewSessionID()
	}
	s.sessionID = sessionID

	dir := filepath.Join(s.GetDir(), sessionID)
	s.sessionDir = dir
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("create session dir: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "images"), 0755); err != nil {
		return fmt.Errorf("create image dir: %w", err)
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
	if realCwd, err := filepath.EvalSymlinks(cwd); err == nil {
		cwd = realCwd
	}
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
		/* 优先用 events.jsonl 的 mtime，fallback 到目录 mtime（对齐 bash/rust） */
		mt, err := e.Info()
		if err != nil {
			continue
		}
		if fi, err := os.Stat(filepath.Join(projectDir, e.Name(), "events.jsonl")); err == nil {
			mt = fi
		}
		if mt.ModTime().Unix() > latestTs {
			latestTs = mt.ModTime().Unix()
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
	if maxUserTurns <= 0 {
		maxUserTurns = 10
	}

	f, err := os.Open(file)
	if err != nil {
		return nil
	}
	defer f.Close()

	offsets := make([]int64, maxUserTurns)
	reader := bufio.NewReader(f)
	var pos int64
	seen := 0
	for {
		line, err := reader.ReadString('\n')
		if line != "" {
			if strings.Contains(line, `"type":"user_input"`) {
				offsets[seen%maxUserTurns] = pos
				seen++
			}
			pos += int64(len(line))
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil
		}
	}
	if seen == 0 {
		return nil
	}

	startOffset := offsets[0]
	if seen >= maxUserTurns {
		startOffset = offsets[seen%maxUserTurns]
	}
	if _, err := f.Seek(startOffset, io.SeekStart); err != nil {
		return nil
	}

	reader = bufio.NewReader(f)
	var lines []string
	for {
		line, err := reader.ReadString('\n')
		line = strings.TrimRight(line, "\r\n")
		if line != "" {
			lines = append(lines, line)
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil
		}
	}
	return lines
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
		output := r.Output
		if r.ConvOutput != "" {
			output = r.ConvOutput
		}
		buf.WriteString(UtilBuildToolResultJSON(r.ToolID, output, "tool_result"))
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
		if isRealUserLine(line) {
			count++
		}
	}
	return count, nil
}

func isRealUserLine(line string) bool {
	var msg struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal([]byte(line), &msg); err == nil {
		var content string
		return msg.Role == "user" && json.Unmarshal(msg.Content, &content) == nil
	}
	return strings.Contains(line, `"role":"user"`) && !strings.Contains(line, `"content":[`)
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
		if isRealUserLine(line) {
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
	if s.stats.TotalRequests > 0 && s.stats.InputTokens > 0 {
		avg = float64(s.stats.InputTokens) / float64(s.stats.TotalRequests)
	}

	// R = total expected remaining LLM calls
	R := E * L

	// cumulative retention
	c := s.stats.TotalCompact
	r := cfg.DPRetention
	if r == 0 {
		r = 0.8
	}
	rT := 1.0
	for i := 0; i <= c; i++ {
		rT *= r
	}
	if rT < 0.37 {
		rT = 0.37
	}

	V := float64(cfg.DPVPrefix) // fixed prefix tokens
	if V == 0 {
		V = 5000
	}
	S := float64(cfg.DPSummaryLen)
	if S == 0 {
		S = 500
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
		minRatio = 0.25
	}
	beta := cfg.DPBeta
	if beta == 0 {
		beta = 0.03
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

	// Maximum lines to keep (hard ceiling) = 1 - minRatio.
	// Rationale: if k > 75% of NR, less than 25% is dropped — too little to
	// justify the cost of an LLM summary call.  This also prevents pathological
	// cases where turn-alignment would expand a small best_k backward past many
	// tool_result lines, inflating the actual keep ratio far above min_keep
	// (e.g. DP picks 25% but turn-alignment pushes it to 80%+), resulting in a
	// compact that barely trims anything while still consuming a full LLM call.
	maxKeep := int(float64(n)*(1.0-minRatio) + 0.5)
	if maxKeep > n {
		maxKeep = n
	}
	// When minRatio > 0.5, the ceiling drops below the floor and the
	// for-loop can never execute.  The user set a high min_keep to be
	// conservative — not to disable compression entirely — so fall back to
	// no ceiling and let DP search up to n.
	if maxKeep < minKeep {
		maxKeep = n
	}

	// H_min: minimum tokens to drop — must be several × summary output cost (S)
	// Dropping less than H_min means compact costs more than it saves.
	// 20×S: with S=500, requires dropping ≥10k tokens to justify a compact call.
	// At R≈20 remaining calls, 10k drop saves $0.06 vs $0.04 cost — clear margin.
	hMin := 20.0 * S

	bestK := 0
	bestBenefit := -1e18

	for k := minKeep; k <= maxKeep; k++ {
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
		compactCost := (pCache*V + pInput*(float64(H)+lInstr) + pOut*S) / 1e6

		// ⑤ Quality savings: 压缩减少上下文长度 → 改善回答质量 → 减少重试成本
		//   不压缩: QP * p_input * (V+T)² / (M*1e6)
		//   压缩后: QP * p_input * (V+K)² / (M*1e6)
		//   增量收益 = 差值
		maxCtx := float64(cfg.MaxContextTokens)
		if maxCtx <= 0 {
			maxCtx = 200000
		}
		qp := cfg.DPQualityPenalty
		if qp == 0 {
			qp = 0.2 // 默认开启，基于 "Lost in the Middle" 论文
		}
		// ⑤ Quality savings: only when context is large enough (> maxCtx × 30%)
		qualitySavings := 0.0
		if float64(totalTokens) > maxCtx*0.30 {
			vPlusT := V + float64(totalTokens)
			vPlusK := V + float64(K)
			qualitySavings = qp * pInput * (vPlusT*vPlusT - vPlusK*vPlusK) / (maxCtx * 1e6)
		}

		benefit := savings - cacheMiss - compactCost - infoLoss + qualitySavings

		if benefit > bestBenefit {
			bestBenefit = benefit
			bestK = k
		}
	}

	if bestBenefit > 0 {
		// Align to user-message (turn) boundary — must cut at user turn
		adj := bestK
		cut := n - adj
		for cut > 0 && roles[cut] != "user" {
			cut--
		}
		adj = n - cut
		if adj < 1 {
			adj = 1
		}

		// Post-alignment guards — alignment result must satisfy both:
		//   1. adj <= maxKeep (alignment must not exceed ceiling)
		//   2. H_actual >= hMin  (tokens dropped must justify summary cost)
		// Cannot fall back to bestK — it is not on a user-message boundary.
		if adj > maxKeep {
			return 0, nil
		}
		kTokens := 0
		for i := n - adj; i < n; i++ {
			kTokens += sizes[i]
		}
		hActual := totalTokens - kTokens
		if hActual < int(hMin) {
			return 0, nil
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
		if isRealUserLine(line) {
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

func (s *FileStore) FormatTitle(model, status string) string {
	st := s.stats
	cacheTotal := st.InputTokens + st.CacheRead
	cachePct := "—"
	if cacheTotal > 0 {
		cachePct = fmt.Sprintf("%.0f%%", float64(st.CacheRead)/float64(cacheTotal)*100)
	}
	prefix := "⏳ "
	if status == "idle" {
		prefix = ""
	}
	progress := 3
	if status == "idle" {
		progress = 0
	}
	return fmt.Sprintf("\x1b]0;%s%s T:%s R:%s I:%s(%s) O:%s C:%s\x07\x1b]9;4;%d\x07",
		prefix,
		model,
		fmtInt(st.TurnCount),
		fmtInt(st.TotalRequests),
		fmtInt(cacheTotal),
		cachePct,
		fmtInt(st.OutputTokens),
		fmtInt(st.ContextTokens),
		progress)
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
// ImageDir — 图像缓存目录
// ═══════════════════════════════════════════

// ImageDir 返回会话图像缓存目录路径
func (s *FileStore) ImageDir() string {
	return filepath.Join(s.sessionDir, "images")
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
	s := strings.TrimLeft(absPath, "/")
	var b strings.Builder
	prevDash := false
	for _, r := range s {
		c := r
		if r == '/' {
			c = '-'
		} else if !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '.' || r == '_' || r == '-') {
			c = '-'
		}
		if c == '-' && prevDash {
			continue
		}
		b.WriteRune(c)
		prevDash = c == '-'
	}
	key := strings.Trim(b.String(), "-")
	key = "-" + key
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
					if utf8.RuneCountInString(line) > 60 {
						line = string([]rune(line)[:57]) + "..."
					}
					row.Preview = line
					break
				}
			}
		}
		rows = append(rows, row)
	}
	// 按 modified 降序排列（对齐 Rust）
	sort.Slice(rows, func(i, j int) bool {
		return rows[i].Modified > rows[j].Modified
	})
	return rows
}
