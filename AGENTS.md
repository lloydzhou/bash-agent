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
