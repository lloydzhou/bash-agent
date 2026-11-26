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
| --prompt-timeout-ms N | 0（不限） | acp prompt 回包等待上限；超时报 error 并结束本轮 |

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
- force_kill：跳过等待，SIGTERM agent 进程组，轮询 2s 未退则 SIGKILL

agent 崩溃 / 强停 / 外部 kill 后，下一轮自动 respawn 并 resume 上一会话。
## 事件流

与 stream-json 模式一致（session_start / user_input / text / thinking /
tool_call / tool_result / usage / stop / error / stderr / process_exit）。
tool_call 与 tool_result 的 name 来自 agent 侧 _meta.bash-agent.name 扩展。

## 会话与恢复

- --session <id>：ACP 模式下双重生效——透传给 agent 命令行，同时作为
  首次握手的 resume 目标（不存在则回退新建）
- --continue：resume 最近活跃会话
- 进程内崩溃恢复：respawn 优先 resume 同进程已知会话，其次启动参数

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
ACP_E2E_STREAM_PORT / ACP_E2E_404_PORT。
