# Agents Guide

## 编译与测试

### 快速命令

```bash
# 编译所有版本
make build

# 运行所有测试
make test

# 清理构建产物
make clean
```

### 分项命令

| 命令 | 说明 |
|------|------|
| `make build-bash` | 编译 Bash 版本到 dist/agent.sh |
| `make build-go` | 编译 Go 版本到 dist/goagent |
| `make build-rust` | 编译 Rust 版本到 dist/rustagent |
| `make test-bash` | 运行 Bash 测试 (tests/test.sh) |
| `make test-go` | 运行 Go 单元测试 |
| `make test-go-e2e` | 运行 Go 版本集成测试 (build + test.sh) |
| `make test-rust` | 运行 Rust 编译检查 |
| `make test-rust-e2e` | 运行 Rust 版本集成测试 (build + test.sh) |

### 测试覆盖

- **tests/test.sh** — 主要的集成测试，覆盖：
  - 工具函数 (agent.sh 中的辅助函数)
  - SubAgent 正常/失败/fork/隔离场景
  - JSON 解析、配置解析
  - 压缩决策 (compact_dp)
  - 统计更新 (stats.awk)

- **go/** — Go 版本单元测试：
  - app_test.go — 核心应用逻辑测试

- **rust/** — Rust 版本检查：
  - cargo check — 编译验证 + 类型检查

### CI 推荐流程

```bash
# 完整检查
make build && make test
```

## 版本一致性要求

Bash / Go / Rust 三个版本的 **system prompt** 和 **tools.json** 必须完全一致。不一致会导致同一 session 切换版本时 LLM 缓存失效（system prompt 不同 → 请求体不同 → cache miss），浪费 token。

### 关键文件

| 文件 | 作用 | 同步说明 |
|------|------|----------|
| `src/tools.json` | 工具定义 JSON | **基准文件**，修改后必须同步到 `rust/src/tools.json` 和 `go/tools.json` |
| `src/agent.sh` | Bash 版 system prompt (`agent_build_prompt`) | **基准**，Go/Rust 的 `BuildPrompt` 必须逐字对齐 |
| `go/agent.go` | Go 版 system prompt (`BuildPrompt`) | 内容、顺序、格式必须与 bash 一致 |
| `rust/src/lib.rs` | Rust 版 system prompt (`build_system_prompt`) | 同上 |

### 检查清单（修改任一 prompt 区域时）

- [ ] `rust/src/lib.rs` 的 `build_system_prompt` 是否同步？
- [ ] `go/agent.go` 的 `BuildPrompt` 是否同步？
- [ ] `go/`、`rust/src/`、`src/` 三处的 `tools.json` SHA256 是否一致？(`sha256sum src/tools.json rust/src/tools.json go/tools.json`)

> **经验**: 同一 session 在三个版本间切换是正常的开发/调试流程。system prompt 不同直接导致缓存失效，每次切换都相当于冷启动。保持一致性就是省钱。
