# DP Compact Algorithm — 设计分析与推导

> 永久参考文档。`plan.md` 中的实现计划变更时，此文档保留完整的设计推理过程。

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
Turn 1: E = 8 - 1 = 7
Turn 5: E = 8 - 5 = 3
Turn 8: E = max(8-8, 8/2) = 4  ← 开始饱和
Turn 20: E = max(8-20, 8/2) = 4
Turn 100: E = max(8-100, 8/2) = 4  ← 恒定
```

**长 session 行为**：超过 DP_BASELINE_E 轮后 E 恒定为 baseline/2。这不影响正确性——上下文大小（dropped_tokens）随会话增长主导收益公式，DP 仍会在上下文够大时触发压缩。

### 跨任务行为

```
Session 生命周期：
  Task 1: 5 轮用户输入 → stats[0] = 5
  Task 2: 新任务 → stats[0] = 6（继续累计）
  E = max(8-6, 4) = 4  ← 仍然合理
```

---

## 4. 数学模型

### 核心公式

```
NetBenefit(k) = E × (P_base - P_cache) × dropped_tokens / 1,000,000 
              - penalty 
              - DP_BETA × (1 - r_cumulative × k/NR)² × N_remain
```

| 符号 | 含义 | 默认值 | 来源 |
|------|------|--------|------|
| E | 预期剩余用户输入轮数 | DP_BASELINE_E - current_turn，见第 3 节 | 见第 3 节 |
| P_base | 未命中缓存的输入价格 ($/MTok) | 3.00 | Claude Sonnet 4 |
| P_cache | 命中缓存的输入价格 ($/MTok) | 0.30 | Claude Sonnet 4 |
| dropped_tokens | total - retained(k) - V | 计算得出 | 从 CONV_FILE |
| retained(k) | 末尾 k 条消息的 token 估算值 | 计算得出 | 从 CONV_FILE |
| V | 固定开销 token 数 | 5,000 | 实测校准（见下方） |
| penalty | 压缩直接开销 ($) | 0.25 | 摘要调用成本 + 缓存未命中成本 |
| r_cumulative | DP_R^c (c = 历史压缩次数) | 0.72^c | 见信息损失模型 |
| DP_R | 单次压缩信息保留率 | 0.72 | Factory AI 数据推导 |
| DP_BETA | 信息损失惩罚系数 | 0.5 | 见参数分析 |
| N_remain | 预期剩余总成本 ($) | E × total_tokens × p_base / 1e6 | 见公式推导 |

### 信息损失模型

#### 递归摘要的指数衰减 + 渐近线

每次压缩的摘要过程会损失一部分关键信息。设单次压缩的信息保留率为 `r`，经过 c 次压缩后，原始信息的累积保留率为：

```
r_cumulative = max(r^c, L)
```

其中：
- `r` = 单次摘要保留率（默认 0.7）
- `c` = 历史压缩次数（`compact_request_count`）
- `L` = 渐近线 = 0.37（Factory AI 测得的极限保留率）

**为什么不是 `r^c` 纯指数？**

递归摘要不是纯乘法过程——某些基础信息（任务目标、关键决策）会在每次摘要中被保留下来。纯指数 `r^c` 会趋于 0，但这与实测不符。加上渐近线 L 后，`c→∞` 时 `r_cumulative → L = 0.37`，与 Factory AI 数据一致。

**单次保留率 r 的估算：**

```
r 取保守值 0.7
```

这样在典型场景（每次压缩保留约 15% 消息）下：
- c=0: r_cumulative = 1.0
- c=1: r_cumulative = max(0.7, 0.37) = 0.7
- c=2: r_cumulative = max(0.49, 0.37) = 0.49
- c=3: r_cumulative = max(0.34, 0.37) = 0.37 ← 触及渐近线
- c≥3: r_cumulative = 0.37

这意味着约 3 次压缩后信息保留不再显著衰减，符合"极限保底"的直觉。

#### 当前压缩的累积保留率

```
r_t(k) = r_cumulative × (k / NR)
```

其中 k/NR 是本次压缩的保留比例。

#### 信息损失的经济代价

```
P_fail = (1 - r_t(k))²          # 信息损失越严重，失败概率增长越快
N_remain = E × total_tokens × p_base / 1e6   # 预期剩余总成本 ($)
info_penalty = DP_BETA × (1 - r_t(k))² × N_remain
```

#### 为什么是二次项？

线性惩罚下，k=1（极端压缩）和 k=4（适度压缩）之间的惩罚差异太小。二次项使得接近零保留率的压缩受到不成比例的高惩罚。

#### r_cumulative 抑制频繁压缩

```
第一次压缩 (c=0):  r_cumulative = 1.0,  r_t = 1.0 × k/NR
第二次压缩 (c=1):  r_cumulative = 0.7,  r_t = 0.7 × k/NR  ← 惩罚更高
第三次压缩 (c=2):  r_cumulative = 0.49, r_t = 0.49 × k/NR ← 惩罚再升
```

这自然抑制了频繁压缩，替代了旧方案中的硬性 min_keep 二次惩罚。

---

## 5. 参数校准（实测数据）

### V = 5000（固定开销 token 数）

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

**首次调用 input_tokens 范围：2,535 - 4,230（均值 ~3,274）**

这包含：system prompt + tools JSON + 首条用户消息。

V 设为 5,000（略高于实测均值）以覆盖：
- system prompt + tools JSON（~3,000-4,000 tokens）
- compact 后的 summary 文本（~1,000 tokens）

**校准前（V=20,000）的问题**：V 被高估 5-6 倍，`dropped = total - retained - V` 的门槛过高，DP 过度保守，上下文需积累到很大才触发压缩。

### DP_BASELINE_E = 8（预期用户输入轮数）

典型开发 session 约 8-15 轮用户输入。设为 8（偏中低），避免过度压缩。

超过 8 轮后 E 饱和为 `baseline/2 = 4`（恒定），但不影响正确性——上下文大小主导收益公式。

### 价格系数（因 provider 而异）

| Provider | P_base | P_cache | Savings/MTok | 压缩偏好 |
|----------|--------|---------|-------------|---------|
| Claude Sonnet 4 | 3.00 | 0.30 | 2.70 | 较激进 |
| DeepSeek | 0.27 | 0.07 | 0.20 | 很保守 |
| GPT-4o | 2.50 | 1.25 | 1.25 | 中等 |

通过环境变量覆盖：`DP_P_BASE=0.27 DP_P_CACHE=0.07 bash-agent ...`

### 参数标定分析

**DP_R=0.7 的估算**：

基于 Factory AI 数据（极限保留率 37%）和指数衰减 + 渐近线模型：
- 约 3 次压缩后触及渐近线 0.37
- r^3 ≈ 0.34, max(0.34, 0.37) = 0.37
- → r ≈ 0.7（保守取整）

**DP_BETA=0.5 的推导**（基于 87k tokens, E=14, c=0 场景）：

| 参数组合 | k=1 净收益 | k=4 净收益 | 最优 k |
|---------|-----------|-----------|--------|
| 无信息惩罚 | $1.96 | $1.63 | k=1（过压缩）|
| β=0.5, 线性 | $1.45 | $1.22 | k=1（仍不够）|
| β=0.5, 二次 | $0.25 | $0.26 | **k=4 ✓** |
| c=1, β=0.5, 二次 | -$0.08 | $0.14 | 边际压缩 ✓ |
                 = 55,000 tokens
```

节省来自**不再发送的 token**（被摘要丢弃的消息）。retained 的消息仍然存在并随每次请求发送，真正省的是 dropped 部分。

**为什么用 dropped = total - retained - V？**

```
不压缩时每次请求发送：total_tokens（全部上下文）
压缩后每次请求发送： V + retained(k)（系统提示 + 本轮输入 + 保留消息）
每次节省：          total - (V + retained) = dropped
```

### 惩罚项设计

#### Penalty = 0.25 的构成

| 成本项 | 计算 | 金额 |
|--------|------|------|
| 摘要调用 — 输入 | ~57k tokens × $3.00/MTok | $0.171 |
| 摘要调用 — 输出 | ~200 tokens × $15/MTok | $0.003 |
| 下次调用缓存未命中 | ~30k tokens × $2.70/MTok | $0.081 |
| **总计** | | **$0.255 ≈ $0.25** |

#### 信息损失惩罚（取代过压缩二次惩罚）

旧方案中的 `deficit² × 10` 二次惩罚被替换为基于信息保留率的经济惩罚：

- `info_penalty = DP_BETA × (1 - r_cumulative × k/NR)² × N_remain`
- 该惩罚在 k << NR 时自然抑制极端压缩，在 r_cumulative 降低时（多次压缩后）自然增加
- 不需要额外的 min_keep 查表或硬阈值

---

## 5. 期望行为矩阵

### 场景：大上下文 (87k tokens, 30 行, DP_BASELINE_E=15)

| LLM 调用 # | E | NetBenefit | 决策 | 保留 k (行) |
|------------|---|------------|------|------------|
| 1 | 14 | $1.88 | 压缩 | 4 行 |
| 5 | 10 | $1.27 | 压缩 | 4 行 |
| 10 | 5 | $0.51 | 压缩 | 4 行 |
| 13 | 2 | $0.05 | 压缩 | 4 行 |
| 14 | 1 | -$0.10 | **不压缩** | — |

### 场景：中等上下文 (28k tokens, 12 行)

| LLM 调用 # | E | NetBenefit | 决策 |
|------------|---|------------|------|
| 1 | 14 | -$0.02 | **不压缩**（dropped 太少） |
| 5 | 10 | -$0.08 | **不压缩** |
| 10 | 5 | -$0.17 | **不压缩** |

### 场景：小上下文 (≤ 20k tokens)

| Turn | E | dropped | 决策 |
|------|---|---------|------|
| 任意 | 任意 | ≤ 0 | **不压缩**（没有可省的 token） |

### 关键行为特征

1. **大上下文 + 多剩余轮次**：强压缩信号
2. **大上下文 + 少剩余轮次**：仍然压缩（节省仍为正）
3. **中等上下文 + 多轮次**：边际压缩信号
4. **中等上下文 + 少轮次**：不压缩（overhead > 节省）
5. **小上下文 (≤ V)**：永不压缩（没有 token 可省）
6. **上下文增长**：行数越多、token 越多，收益上升 → 自然的动态缩放
7. **跨任务重置**：新任务的第一轮用户输入，E 始终从 ≈DP_BASELINE_E 开始（不受历史或 MAX_TURNS 影响）

---

## 6. 决策逻辑

```
对每个 k (1..NR) 计算 NetBenefit(k):

  1. retained = sum of token estimates for last k lines
  2. dropped = total_tokens - retained - V
  3. if dropped ≤ 0: continue (no savings possible)
  4. benefit = E × (P_base - P_cache) × dropped / 1e6 - penalty
  5. if k < min_keep: benefit -= (min_keep - k)² × 10

如果 max(benefit) > 0:
  → 用最优 k 对齐到 user 消息边界
  → 执行压缩（摘要丢弃的部分，保留尾部 k 行）
如果 max(benefit) ≤ 0:
  → 检查 ct = stats_get(7) 是否超过 MAX_CONTEXT_TOKENS × 0.9
  → 如果超过：强制压缩，keep_lines = max(3, NR × DP_MIN_KEEP_RATIO)
  → 否则：不压缩（return 1）
```

---

## 7. awk 实现细节

关键参数传递（通过 `-v`）：

| 变量 | 来源 | 用途 |
|------|------|------|
| E | shell 计算 | 预期剩余步数 |
| V | DP_V | 固定开销 token 数 |
| p_base | DP_P_BASE | 非缓存价格 |
| p_cache | DP_P_CACHE | 缓存价格 |
| penalty | DP_PENALTY | 压缩开销 |
| min_keep_ratio | DP_MIN_KEEP_RATIO | 最小保留比例 |

awk 内部：
- `sizes[NR] = int((length($0) + 3) / 4) + 1` — token 估算（bytes/4）
- `role[NR] = ($0 ~ /^\{"role":"user","content":"/) ? "user" : "other"` — 用于轮次边界对齐
- 双层循环：外层 `for (k=1..NR)`，内层汇总尾部 k 行
- 时间复杂度 O(N²)，N ≤ 几百行，可接受

---

## 8. 边界情况与安全性

| 边界情况 | 行为 |
|----------|------|
| 空 CONV_FILE | awk 中 NR==0 → print "0" |
| 极小对话 (< V tokens) | 所有 k 的 dropped ≤ 0 → 不压缩 |
| 单消息对话 | min_keep = NR → k=NR → dropped ≤ 0 → 不压缩 |
| E=0（超过 DP_BASELINE_E）| E 下限为 baseline/2 | | llm_turn ≥ DP_BASELINE_E | `E = baseline/2`，不会退化为 1 |
| DP 说不压缩，但 ct > MAX_CONTEXT_TOKENS × 90% | 强制压缩，`keep_lines = max(3, NR × DP_MIN_KEEP_RATIO)` |
| 同一用户输入内多次 compact | 压缩后上下文缩小 → dropped 变小 → 下次不触发的概率高 |
| 长 session（stats[0] > baseline）| E 恒定为 baseline/2，dropped_tokens 主导收益 |

---

## 9. 未来优化方向

- **动态 E 估算**：让 LLM 根据任务类型估计剩余步骤数
- **逐消息价值加权**：近期消息权重高于老旧消息
- **Token-字节校准**：用实际 tokenizer 统计替代 bytes/4 启发式
- **自适应 penalty**：根据观察到的摘要调用成本自动调整 DP_PENALTY
- **自适应 min_keep**：基于对话实际结构（rounds 而非 lines）确定 min_keep
- **价格系数自动适配**：根据 provider/model 自动设置 DP_P_BASE/DP_P_CACHE
