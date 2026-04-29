# DP Compact Algorithm — 设计分析与推导

> 实现记录见 `plan.md`。本文档保留完整的设计推导过程。

## 1. 核心问题

### 当前压缩的缺陷

现有的 `compact_context_window` 使用**阈值触发式**策略：

```
EITHER  current_context_tokens > MAX_CONTEXT_TOKENS (200k)
   OR   current_turn_count > MAX_TURNS_BEFORE_COMPACT (100)
→ 保留 25% 的会话 (MAX_CONTEXT_KEEP_PCT)
→ 对齐到轮次边界
→ 摘要被丢弃的消息
```

三个根本问题：
1. **两个独立触发器互不协调** — token 阈值和 turn 阈值各自触发，没有优先级或组合逻辑
2. **固定保留比例 (25%)** — 不与任务阶段、会话大小或剩余工作量适配
3. **无成本收益分析** — 只要触达阈值就压缩，不考虑经济上是否划算

### 解决方案

将"在哪一步压缩"和"保留多少消息"两个决策合二为一。在会话的每一步，计算假设压缩动作的"净收益"，求解最优化方程确定最优 k。

---

## 2. 系统中的"步数"概念

### 两个不同的 turn 计数器

**计数器 A：`stats[0]` (current_turn_count)**

```
agent_loop()                          ← 每次用户输入调用一次
  session_append_line "user_input"    ← 写入 events.jsonl
  stats_inc 0=1                       ← stats[0] +1
  agent_loop_stream(user_input)
```

计数的是 **`agent_loop()` 的调用次数** = 用户输入次数。这是**用户层步数**。

**计数器 B：`agent_loop_stream` 内的局部变量 `turn`**

```
agent_loop_stream(user_input)
  conv_add_user(user_input)           ← 写入 CONV_FILE
  local turn=0
  while (( turn < MAX_TURNS ))        ← MAX_TURNS (默认 40) 控这个循环
    (( turn++ ))
    llm_call → 处理 SSE → 如果 tool_use → 执行工具 → 继续循环
```

计数的是 **LLM API 调用次数**（含 tool 循环内的多次调用）。这是 **API 层步数**。

### 一次用户输入内可能产生多次 LLM 调用

典型的 agent 工作流：

```
用户输入 "实现 DataTable 组件"
  → LLM 调用 #1：分析需求、生成代码 → 调用 Write 工具
    ↪ 工具结果返回，继续循环
  → LLM 调用 #2：验证代码 → 又调 Read 工具
    ↪ 工具结果返回，继续循环
  → LLM 调用 #3：收尾 → stop="end_turn" → break
```

**这一个用户输入 = 3 次 LLM API 调用。**

### CONV_FILE 中 user 消息的双重含义

`CONV_FILE` (conversation.jsonl) 里的 `{"role":"user"}` 消息包含两类：

| 来源 | 函数 | 格式 |
|------|------|------|
| 真实用户输入 | `conv_add_user()` | `{"role":"user","content":"用户文本"}` |
| tool 执行结果 | `conv_add_tool_results()` | `{"role":"user","content":[tool_results]}` |

直接 `grep '"role":"user"' "$CONV_FILE"` 会**重复计数**（把 tool 结果也算作"步数"）。

### 第 901 行的 bug

```bash
remaining_turns=$(grep -c '"type":"user_input"' "$CONV_FILE")
```

`CONV_FILE` 使用 `"role"` 字段而非 `"type"` 字段。此 grep 不会匹配任何行，应改为读 `events.jsonl` 或重构计数方式。

---

## 3. E（预期剩余步数）的精确语义

### E 的定义：预期剩余用户输入轮数

E 代表"还有多少轮用户输入会触发 agent_loop_stream 调用"。压缩的经济收益来自未来每轮用户输入中的 LLM 调用——每次 LLM 调用都发送完整上下文，压缩后上下文更小，每次调用都省钱。

### 为什么用 stats[0]（用户输入轮数）而不是 LLM 调用次数？

- 压缩的切分边界对齐到**真实用户输入**（`{"role":"user","content":"`），不会在 tool 结果处切断
- 压缩以"用户输入轮"为单位丢弃历史 → E 也应以"用户输入轮"为度量
- `stats[0]` = `current_turn_count`，由 `agent_loop()` 在每次用户输入时 +1

### E 的计算

```bash
current_turn=$(stats_get 0)
baseline=${DP_BASELINE_E:-8}

if (( DP_E_FIXED > 0 )); then
    E=$DP_E_FIXED
elif (( baseline > 0 )); then
    remaining=$(( baseline - current_turn ))
    if (( remaining <= 0 )); then
        E=$(( baseline > 1 ? baseline / 2 : 2 ))
    else
        E=$remaining
    fi
else
    E=2
fi
```

**E 的衰减行为：**

```
Turn 1: E = max(8-1, 4) = 7
Turn 5: E = max(8-5, 4) = 4  ← 达到下限
Turn 7: E = max(8-7, 4) = 4
Turn 8: E = max(0, 4) = 4
Turn 20: E = max(-12, 4) = 4
Turn 100: E = max(-92, 4) = 4
```

E 始终 = max(remaining, baseline/2)，单调非递增，无跳变。

### 跨任务行为

```
Session 生命周期：
  Task 1: 5 轮用户输入 → stats[0] = 5
  Task 2: 新任务 → stats[0] = 6（继续累计）
  E = max(8-6, 4) = 4  ← 仍然合理
```

---

## 4. 数学模型

### 最终决策公式

```
NetBenefit(k) = ① - ② - ③ - ④

① (R-1) × P_cache × H / 1e6                             后续 LLM 调用节省的缓存读取成本
② (S + K) × (P_input - P_cache) / 1e6                    压缩后首次 LLM 调用的缓存失效损失
③ [P_cache×(V+H) + P_input×L_instr + P_out×S] / 1e6     压缩请求成本
④ β × (1 - r^(c+1)) × R × avg × P_input / 1e6           信息失真预期成本
```

**决策规则**：若存在 k 使 NetBenefit(k) > 0，选择最大收益的 k 执行压缩；否则不压缩。

### 各项详细含义

#### ① 后续 LLM 调用节省的缓存读取成本

压缩后上下文缩短 H 个 token（被丢弃的旧消息）。整个任务预期还有 R = E × L 次 LLM 调用。第一次调用因缓存断裂无法节省，因此受益调用次数为 R - 1。每次调用节省 P_cache × H。

#### ② 压缩后首次 LLM 调用的缓存失效损失

前缀匹配缓存（Prefix Caching）从请求的第一个 token 开始逐 token 哈希比对。摘要内容变化后，从摘要第一个 token 起所有后续 token 都失去缓存匹配。失效区域 = 新摘要 S + 保留消息 K，按 (P_input - P_cache) 的价差计费。

#### ③ 压缩操作本身的请求成本

压缩请求采用**缓存复用策略**：前缀保持旧摘要不变（V = system prompt + tools + old summary），加上被丢弃消息 H。这些命中缓存按 P_cache 计费。末尾追加的指令 L_instr 无法命中按 P_input 计费。输出 S 按 P_out 计费。

#### ④ 信息失真带来的预期额外成本

增量摘要每次都有信息损失。累积保留率 r_t = r^(c+1)，与 k 无关。β 是折算系数，N_remain = R × avg 估算剩余任务规模。

### 变量定义

| 变量 | 含义 | 获取方式 | 单位 |
|------|------|----------|------|
| E | 预期剩余用户输入轮数 | DP_BASELINE_E - current_turn | 轮 |
| L | 每轮用户输入平均 LLM 调用次数 | DP_L（默认 5）或 stats[1]/stats[0] | 次/轮 |
| R = E × L | 预期剩余 LLM 请求总次数 | 计算 | 次 |
| k | 保留的最近消息条数 | 决策变量 | 条 |
| K | 保留消息的总 token 数 | CONV_FILE 末尾 k 行 token 之和 | token |
| H | 拟丢弃的旧消息 token 数 | total_tokens - K | token |
| S | 固定摘要长度 | DP_S = 500 | token |
| V | 固定前缀长度（system prompt + tools + old summary） | DP_V = 5000 | token |
| L_instr | summary 指令 token 数 | 硬编码 70 | token |
| P_input | 未命中缓存输入价格 | DP_P_INPUT = 3.00 | $/MTok |
| P_cache | 缓存命中输入价格 | DP_P_CACHE = 0.30 | $/MTok |
| P_out | 输出价格 | DP_P_OUT = 15.00 | $/MTok |
| r | 单次摘要信息保留率 | DP_R = 0.8 | 比率 |
| r_t | 累积保留率 | r^(c+1)，下限 0.37 | 比率 |
| β | 信息损失折算系数 | DP_BETA = 0.03 | 无量纲 |
| avg | 每次 LLM 请求平均 input token 数 | stats[3]/stats[1] 或 4000 | token |

### 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| DP_P_INPUT | 3.0 | $/MTok，未命中缓存的输入价格 |
| DP_P_CACHE | 0.30 | $/MTok，命中缓存的输入价格 |
| DP_P_OUT | 15.0 | $/MTok，输出价格 |
| DP_V | 5000 | 固定前缀 token 数 |
| DP_S | 500 | 固定摘要长度 token 数 |
| DP_L | 5 | 每轮用户输入平均 LLM 调用次数 |
| DP_BASELINE_E | 8 | 预期剩余用户输入轮数 |
| DP_E_FIXED | 0 | 固定 E（0=使用 DP_BASELINE_E 计算） |
| DP_R | 0.8 | 单次摘要信息保留率 |
| DP_BETA | 0.03 | 信息损失折算系数 |
| DP_MIN_KEEP_RATIO | 0.12 | 最少保留消息比例 |


### 信息损失模型

#### 累积保留率

每次压缩都存在信息损失。累积保留率 r_t = r^(c+1)，其中 c 是历史压缩次数。下限 0.37 来自 Factory AI 实测数据——递归摘要不会趋于零。

```
c=0: r_t = 0.8^1 = 0.80
c=1: r_t = 0.8^2 = 0.64
c=2: r_t = 0.8^3 = 0.512
c=3: r_t = 0.8^4 = 0.41
c≥4: r_t → max(r^(c+1), 0.37)
```

r_t 与 k 无关——它只反映历史压缩次数对信息完整性的累积影响。这确保多次压缩被递增惩罚，防止灾难性遗忘。

#### info_loss 的计算

```
N_remain = R × avg            （预期剩余总 input token 数）
info_loss = β × (1 - r_t) × N_remain × P_input / 1e6
```

β = 0.03 的含义：假设信息损失导致 10k token 的修复成本 = 10000 × 3.0 / 1e6 = $0.03。

---

## 5. 参数校准（实测数据）

### V = 5000（固定前缀 token 数）

从 6 个真实 session 的首次 usage event 统计：

```
Session                        input_tokens
20260426-230651                    3,116
20260424-142959                    2,535
20260425-121147                    2,729
feature-summary-refactor           4,082
feature-stats                      2,949
feature-summary-refactor-fit       4,230  (cache_read: 384)
```

首次调用 input_tokens 范围：2,535 - 4,230（均值 ~3,274）。包含 system prompt + tools JSON + 首条用户消息。

V = 5,000 覆盖 system prompt (~3k-4k) + summary (~1k)。

### L = 5（每轮平均 LLM 调用次数）

Claude Code 45天数据分析：
- 总助手响应 37,476 次 / 总用户输入 4,378 次 ≈ 8.56 次/用户输入
- 行业基准：单次 Agent 任务 5-15 次 API 调用
- 取 5 作为保守基线，避免过度压缩

L 可通过 stats 自动计算（`stats[1]/stats[0]`），DP_L=0 时启用自动计算。

### DP_BASELINE_E = 8

典型开发 session 约 8-15 轮用户输入。取 8 偏中低。超过 8 轮后 E 饱和为 baseline/2 = 4。

### DP_BETA = 0.03

信息损失折算系数。含义：损失 1% 信息在 R × avg = 60k token 的剩余任务中，预期额外成本 = 0.03 × 0.01 × 60000 × 3.0 / 1e6 ≈ $0.000054。

### DP_R = 0.8

单次摘要保留率。基于 Factory AI 实测（极限保留率 37%）反推：r^3 ≈ 0.34 < 0.37，约 3-4 次压缩后触及渐近线。

### 价格系数（因 provider 而异）

| Provider | P_input | P_cache | P_out | Savings/MTok | 压缩偏好 |
|----------|---------|---------|-------|-------------|---------|
| Claude Sonnet 4 | 3.00 | 0.30 | 15.00 | 2.70 | 较激进 |
| GPT-4o | 2.50 | 1.25 | 10.00 | 1.25 | 中等 |
| DeepSeek v4 flash | 1.00 | 0.02 | 3.00 | 0.98 | 保守 |

通过环境变量覆盖：`DP_P_INPUT=1.00 DP_P_CACHE=0.02 bash-agent ...`


### 使用示例

假设会话第 8 轮（t=8），累积上下文 120k token，固定前缀 30k token。保留最近 3 轮消息（k=3），K=25k，H=120k-25k=65k（注：H=total-K，V 不参与 H 计算）。预估 E=5，L=3，R=15。S=500，c=1，r_t=0.8^2=0.64。β=0.03，avg=4k。

```
① = (15-1) × 0.30 × 65000 / 1e6 = 14 × 0.0195 = 0.273
② = (500+25000) × (3.00-0.30) / 1e6 = 25500 × 2.7e-6 = 0.0689
③ = (0.30×(5000+65000) + 3.00×70 + 15.00×500) / 1e6
   = (21000 + 210 + 7500) / 1e6 = 0.0287
④ = 0.03 × (1-0.64) × 15 × 4000 × 3.0 / 1e6
   = 0.03 × 0.36 × 0.18 = 0.00194

NetBenefit = 0.273 - 0.0689 - 0.0287 - 0.00194 = $0.173 → 正收益，执行压缩
```

---

## 6. E 的计算

```bash
current_turn = stats_get 0
if DP_E_FIXED > 0:
    E = DP_E_FIXED
elif DP_BASELINE_E > 0:
    remaining = DP_BASELINE_E - current_turn
    floor = DP_BASELINE_E / 2
    E = max(remaining, floor)
else:
    E = 2
```

E = max(DP_BASELINE_E - t, baseline/2)，单调非递增，无跳变。
```
Turn 1: E = max(7, 4) = 7,  R = 35
Turn 5: E = max(3, 4) = 4,  R = 20
Turn 8: E = max(0, 4) = 4,  R = 20
Turn 20: E = max(-12, 4) = 4,  R = 20
```

长 session 中 E 以 baseline/2 为下限，但上下文大小主导收益，DP 仍正确触发。

---

## 7. 决策逻辑

```
对每个 k (min_keep..NR) 计算 NetBenefit(k):

  1. K = sum of token estimates for last k lines
  2. H = total_tokens - K
  3. if H <= 0: continue

  4. ① savings = (R-1) × P_cache × H / 1e6
  5. ② cache_miss = (S + K) × (P_input - P_cache) / 1e6
  6. ③ compact_cost = [P_cache×(V+H) + P_input×L_instr + P_out×S] / 1e6
  7. ④ info_loss = β × (1-r^(c+1)) × R × avg × P_input / 1e6

  8. benefit = ① - ② - ③ - ④

如果 max(benefit) > 0:
  → 用最优 k 对齐到 user 消息边界
  → 执行压缩
如果 max(benefit) <= 0:
  → 检查 ct = stats_get(7) 是否超过 MAX_CONTEXT_TOKENS × 90%
  → 如果超过：强制压缩，keep_lines = max(3, NR × DP_MIN_KEEP_RATIO)
  → 否则：不压缩
```

### 边界对齐

压缩切分点对齐到真实用户输入（`{"role":"user","content":"`），不会在工具结果处切断：

```awk
cut = NR - k
while (cut > 1 && role[cut] != "user") {
    cut--
    adj = NR - cut
}
```

---

## 8. 边界情况与安全性

| 边界情况 | 行为 |
|----------|------|
| 空 CONV_FILE | NR==0 → print "0" |
| 极小对话 (< min_keep 行) | min_keep = NR → k=NR → H=0 → 不压缩 |
| E=0（超过 DP_BASELINE_E） | E 下限为 baseline/2 |
| DP 说不压缩，但 ct > 90% | 强制压缩，keep_lines = max(3, NR × DP_MIN_KEEP_RATIO) |
| 同一用户输入内多次 compact | 压缩后 H 变小 → 下次不触发 |
| 长 session（stats[0] > baseline） | E 恒定 baseline/2，H 主导收益 |
| c ≥ 4（多次压缩） | r_t 触及 0.37 下限，④ 不再增长 |

---

## 9. 文件清单

| 文件 | 说明 |
|------|------|
| `src/awk/compact_dp.awk` | AWK 实现核心公式（91 行） |
| `src/agent.sh` | config 区域 + compact_dp_decision() + compact_context_window() |
| `go/internal/conversation/compact_dp.go` | Go 实现（171 行） |
| `go/internal/config/config.go` | Go DP 配置字段 + 环境变量覆盖 |
| `rust/src/compact_dp.rs` | Rust 实现（150 行） |
| `rust/src/config.rs` | Rust DP 配置字段 + 环境变量覆盖 |
| `docs/dp-compact-analysis.md` | 本文档 |
| `plan.md` | 实现记录 |
