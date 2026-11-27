# webagent

手机浏览器友好的 agent 网关：起一个本地 WS 服务，把浏览器输入转发给 agent，
把 agent 事件流还原成前端可识别的格式广播。支持两种后端协议。

## 启动

```bash
# 默认 stream-json 模式（每轮 spawn 一次 agent，行为与旧版完全一致）
webagent --agent /path/to/agent.sh --port 8686

# ACP 模式（常驻 agent 进程，Agent Client Protocol）
webagent --agent /path/to/agent.sh --protocol acp --port 8686
```

浏览器打开 http://<bind>:<port>/ （局域网手机访问用 --bind 0.0.0.0）。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| --bind ADDR | 127.0.0.1 | 监听地址 |
| --port PORT | 8686 | 监听端口 |
| --agent PATH | dist/cagent | agent 可执行文件 |
| --protocol P | stream-json | acp 或 stream-json |
| --cancel-timeout-ms N | 10000 | acp 取消确认超时；超时后 UI 提供「强制停止」 |

其余位置参数原样透传给 agent（如 --model、--provider、--session <id>、--continue）。
## 两种协议

### stream-json（默认）

每轮用户输入 spawn 一次 agent（--output-format stream-json），解析 stdout
事件行转发给前端。行为与旧版 webagent 完全一致，零迁移成本。

### acp

常驻一个 agent 进程，按 Agent Client Protocol（JSON-RPC over
stdin/stdout）通信：

- 启动握手：initialize -> session/new（或 session/resume，失败自动
  回退 session/new 并向前端发 stderr 提示「原 ACP 会话不可恢复，已新建会话」）
- 每轮：WS 输入包装成 session/prompt，session/update 通知还原成与
  stream-json 模式完全一致的前端事件（text/thinking/tool_call/tool_result 等）
- 对 agent 发起的未知反向请求（如 session/request_permission）回
  -32601 Method not found，agent 可自行降级，不会挂死

## ACP 模式控制消息

WS 发送命名空间 JSON（注意：裸 {"type":"cancel"} 是普通文本，会当
prompt 送达 agent）：

```json
{"type": "bashagent_ctrl", "action": "cancel"}
{"type": "bashagent_ctrl", "action": "force_kill"}
```

- cancel：发 session/cancel 通知，等待 agent 回 stopReason=cancelled
  （上限 --cancel-timeout-ms）
- force_kill：跳过等待，先 SIGTERM agent 进程组（有进行中轮次时 agent 走
  完整取消并以 cancelled 收尾，约 3s），最多等 5s 排空，未退再 SIGKILL
  （再等 2s）

### 强停 / 异常退出收尾

agent.sh 的 worker 在后台子 shell 里跑工具、收通知，这些子 shell 各自成
进程组，且持有 stdout 写端。所以进程是否退出不能只看 stdout EOF：孤儿不退，
EOF 永远不来。webagent 的做法：

- agent 存活期间由后台线程持续记录它的后代进程组快照（启动后头 2s 每
  250ms，之后每 1s；SIGTERM 前再刷新一次。已记录的组只要有存活成员就保留）
- 根进程一退出（`child.wait()` 返回，强停 / 崩溃 / 被 `kill -9` 均适用），
  立即对快照里的进程组发 SIGKILL 清理孤儿，再广播 `process_exit`
- 因此无论强停、崩溃还是被 `kill -9`，都保证：`process_exit` 必达、不残留
  agent 进程、下一轮自动 respawn 并 resume 上一会话（无需 stdout EOF）
- 已知边界：意外退出只能用最近一次快照，退出前不到一个采样周期（≤1s）
  新建的进程组可能漏清

Ctrl+C 退出 webagent 走同一条收尾路径（先 SIGTERM 等排空，超时 SIGKILL），
退出后不残留 agent 进程。

## 事件流

与 stream-json 模式一致（session_start / user_input / text / thinking /
tool_call / tool_result / usage / stop / error / stderr / process_exit）。
tool_call 与 tool_result 的 name 来自 agent 侧 _meta.bash-agent.name 扩展；
tool_call_update 的 in_progress 中间态不映射，只有 completed/failed 才转成
tool_result（避免前端把中间态当结果提前收尾工具卡片）。

## 会话与恢复

- --session <id>：ACP 模式下双重生效——透传给 agent 命令行，同时作为
  首次握手的 resume 目标（不存在则回退新建）
- --continue：resume 最近活跃会话
- 进程内崩溃恢复：respawn 优先 resume 同进程已知会话，其次启动参数
- agent 侧 worker 崩溃：agent 自动回收死 worker（wait 僵尸、清 busy/cancel
  标志与 notify 孤儿、重建 FIFO），session/resume 会重新拉起 worker；
  session/prompt 收到 -32002 时 webagent 自动注销当前 client，下一轮
  respawn 并 resume 同一会话，无需用户操作

## 环境变量

- BASH_AGENT_HOME：agent 数据目录（默认 $HOME），events/stats 落盘于
  $BASH_AGENT_HOME/.bash-agent/projects/<project_key>/<sid>/

## 测试

```bash
cargo build --manifest-path webagent/Cargo.toml
python3 -m pip install websockets   # E2E 依赖
bash tests/test_webagent_acp.sh     # E2E（mock agent + 真实 agent.sh）
cargo test --manifest-path webagent/Cargo.toml
```

E2E 端口可用环境变量覆盖：ACP_E2E_LLM_PORT / ACP_E2E_PORT /
ACP_E2E_REAL_PORT / ACP_E2E_CANCEL_PORT / ACP_E2E_KILL_PORT /
ACP_E2E_STREAM_PORT / ACP_E2E_404_PORT / ACP_E2E_STRONG_PORT /
ACP_E2E_QUICK_PORT。
