# bash-agent Vim 插件

[English](README_EN.md)

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
| `:AgentToggle` | 打开/隐藏右侧 agent 终端；冷启动时使用续聊命令 |
| `:AgentToggle!` | 使用新会话命令；已运行则杀掉当前进程并重启 |
| `:[range]AgentSend` | 把 `[range]`（或可视选择）的代码写入临时文件，向 agent 注入引用 |
| `:AgentSendBuffer` | 整个缓冲区同上 |
| `:AgentAsk <text>` | 直接向 agent 注入任意文本 |

注入的文本不会自动回车提交，你在 agent 终端里确认后再发送。

## 推荐快捷键

### Leader 键方案

```vim
nmap <leader>aa <Plug>(agent-toggle)      " 开/关 agent（续聊）
nmap <leader>an <Plug>(agent-new)         " 新会话
xmap <leader>as <Plug>(agent-send)        " 发送选中代码
nmap <leader>ab <Plug>(agent-send-buffer) " 发送整个文件
```

### F 键方案

下面以 F12 开关侧边栏、Shift-F12 创建新会话为例。相比另占一个 F 键，Shift-F12 更不容易与 macOS 的系统快捷键冲突：

```vim
" 普通编辑窗口
nmap <silent> <F12> <Plug>(agent-toggle)
nmap <silent> <S-F12> <Plug>(agent-new)

" 焦点在 agent 终端时，也允许按 F12 隐藏侧边栏
if has('nvim')
  tnoremap <silent> <F12> <C-\><C-N>:AgentToggle<CR>
else
  tnoremap <silent> <F12> <C-W>:AgentToggle<CR>
endif
```

如果 F 键没有触发，先检查映射是否加载，以及是否被其他插件覆盖：

```vim
:verbose nmap <F12>
:verbose tmap <F12>
```

macOS 可能把 F1–F12 当作系统功能键，需要使用 `Fn+F12`，或者在系统键盘设置中将其改为标准功能键。

### 浏览终端历史输出

agent 终端处于输入模式时，滚动键通常会被 CLI 接收。先进入终端普通模式，再用 Vim 按键浏览：

- Vim 8：按 `Ctrl-W N`
- Neovim：按 `Ctrl-\ Ctrl-N`
- `Ctrl-U` / `Ctrl-B`：向上翻半页 / 一页
- `Ctrl-D` / `Ctrl-F`：向下翻半页 / 一页
- `gg` / `G`：跳到最早 / 最新内容
- 浏览结束后按 `i`：回到 CLI 输入模式

Vim 8 可增加终端历史保留行数：

```vim
if exists('+termwinscroll')
  set termwinscroll=50000
endif
```

## 配置

### 默认命令

```vim
" 兼容的基础命令配置（默认值）
let g:agent_command = 'ccagent --interactive'

" 终端宽度（默认 max([40, &columns*2/5])）
let g:agent_width = 50
```

未配置其他启动命令时：

- `:AgentToggle!` 运行 `g:agent_command`
- 冷启动 `:AgentToggle` 运行 `g:agent_command --continue`

### 分别配置新会话和续聊命令

插件支持从 Vim 进程环境中读取两个完整启动命令：

| 环境变量 | 对应操作 |
|---|---|
| `AGENT_NEW_COMMAND` | `:AgentToggle!`，杀掉现有侧边栏进程并启动新会话 |
| `AGENT_CONTINUE_COMMAND` | 冷启动 `:AgentToggle`，续聊已有会话 |

环境变量未设置或值为空时，会回退到上面的原有默认行为。

推荐写入 `~/.zshrc`，然后重新打开终端或执行 `source ~/.zshrc`：

```zsh
export AGENT_NEW_COMMAND='ccagent --interactive'
export AGENT_CONTINUE_COMMAND='ccagent --interactive --continue'
```

必须先设置环境变量，再启动 Vim：

```zsh
source ~/.zshrc
vim README.md
```

进入 Vim 后可确认是否成功继承：

```vim
:echo $AGENT_NEW_COMMAND
:echo $AGENT_CONTINUE_COMMAND
```

如果从图形界面启动 Vim，没有加载 `~/.zshrc`，也可以直接写在 `~/.vimrc`：

```vim
let $AGENT_NEW_COMMAND = 'ccagent --interactive'
let $AGENT_CONTINUE_COMMAND = 'ccagent --interactive --continue'
```

### 集成 Claude Code

```zsh
export AGENT_NEW_COMMAND='claude'
export AGENT_CONTINUE_COMMAND='claude --continue'
```

### 集成 Codex

```zsh
export AGENT_NEW_COMMAND='codex'
export AGENT_CONTINUE_COMMAND='codex resume --last'
```

请按本机安装的 Codex CLI 版本调整续聊参数。

选择 Claude、Codex 或其他 CLI 后，应让 `AGENT_NEW_COMMAND` 和 `AGENT_CONTINUE_COMMAND` 配置为同一 CLI 的新会话与续聊命令。插件不会在不同 CLI 之间自动切换；运行中的 `:AgentToggle` 只负责显示或隐藏当前进程。

### 命令中设置额外环境变量

`term_start()` 不会把开头的 `NAME=value` 当成 shell 赋值执行。需要使用 `env`：

```zsh
export AGENT_CONTINUE_COMMAND='env DP_P_INPUT=22.5 DP_P_OUT=45 DP_P_CACHE=1 ccagent --interactive --continue'
```

不要在命令末尾添加 `$@`；这里配置的是完整启动命令，不是 shell 函数定义。

### 调用 `~/.zshrc` 中的函数

假设 `~/.zshrc` 中已有：

```zsh
open_codex() {
  codex "$@"
}

open_claude() {
  claude --continue "$@"
}
```

使用交互式 zsh 加载函数：

```zsh
export AGENT_NEW_COMMAND='zsh -ic open_codex'
export AGENT_CONTINUE_COMMAND='zsh -ic open_claude'
```

不能只配置函数名，例如 `AGENT_NEW_COMMAND='open_codex'`，因为 zsh 函数不是独立可执行文件。

注意：C 版 `ccagent` 只有 `--interactive`（无 `-i` 短选项）。

## 测试

```bash
# headless 单测（context 构建）
vim -Nu NONE -n -es -S vim/test/test_build_context.vim </dev/null

# PTY 冒烟测试（用 cat 冒充 agent，验证终端/注入/退出全流程）
python3 vim/test/smoke.py
```
