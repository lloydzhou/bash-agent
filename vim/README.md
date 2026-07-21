# bash-agent Vim 插件

在 Vim 8+ / Neovim 中用右侧常驻分屏运行 `ccagent`（VSCode 式布局：左编辑区、右 chat），并可把选中代码 / 整个缓冲区注入 agent 输入行。

## 安装

Vim 8 原生 package（软链方式，改代码立即生效）：

```bash
mkdir -p ~/.vim/pack/local/start
ln -s /path/to/bash-agent/vim ~/.vim/pack/local/start/agent
```

Neovim：

```bash
mkdir -p ~/.local/share/nvim/site/pack/local/start
ln -s /path/to/bash-agent/vim ~/.local/share/nvim/site/pack/local/start/agent
```

## 命令

| 命令 | 说明 |
|------|------|
| `:AgentToggle` | 打开/隐藏右侧 agent 终端，启动时自动追加 `--continue` 续聊最近会话 |
| `:AgentToggle!` | 新会话（不带 `--continue`；已运行则杀掉重启） |
| `:[range]AgentSend` | 把 `[range]`（或可视选择）的代码写入临时文件，向 agent 注入引用 |
| `:AgentSendBuffer` | 整个缓冲区同上 |
| `:AgentAsk <text>` | 直接向 agent 注入任意文本 |

注入的文本不会自动回车提交，你在 agent 终端里确认后再发送。

## 推荐快捷键

```vim
nmap <leader>aa <Plug>(agent-toggle)      " 开/关 agent（续聊）
nmap <leader>an <Plug>(agent-new)         " 新会话
xmap <leader>as <Plug>(agent-send)        " 发送选中代码
nmap <leader>ab <Plug>(agent-send-buffer) " 发送整个文件
```

## 配置

```vim
" agent 命令（默认值）
let g:agent_command = 'ccagent --interactive'

" 终端宽度（默认 max([40, &columns*2/5])）
let g:agent_width = 50
```

注意：C 版 `ccagent` 只有 `--interactive`（无 `-i` 短选项）。

## 测试

```bash
# headless 单测（context 构建）
vim -Nu NONE -n -es -S vim/test/test_build_context.vim </dev/null

# PTY 冒烟测试（用 cat 冒充 agent，验证终端/注入/退出全流程）
python3 vim/test/smoke.py
```
