# bash-agent Vim Plugin

[中文文档](README.md)

Run `ccagent` in a persistent right-side split in Vim 8+ or Neovim, using a VS Code-style layout with the editor on the left and chat on the right. The plugin can also inject selected code or the entire current buffer into the agent input line.

> **Send mechanism**
> - `AgentSend`: pastes the selected code into the agent input box via **bracketed paste** (no temp file).
> - `AgentSendBuffer`: injects an **`@/abs/path`** reference for saved, unmodified buffers (the agent reads the file via its Read tool); unsaved or modified buffers fall back to pasting the current content.

## Installation

Vim 8 native packages using a symlink, so local changes take effect immediately:

```bash
mkdir -p ~/.vim/pack/local/start
ln -s /path/to/bash-agent/vim ~/.vim/pack/local/start/agent
```

Neovim:

```bash
mkdir -p ~/.local/share/nvim/site/pack/local/start
ln -s /path/to/bash-agent/vim ~/.local/share/nvim/site/pack/local/start/agent
```

## Commands

| Command | Description |
|---|---|
| `:AgentToggle` | Show or hide the agent terminal. When starting a process, use the continue command. |
| `:AgentToggle!` | Use the new-session command. If a process is running, stop it and restart. |
| `:[range]AgentSend` | Paste the range or visual selection into the agent input box via bracketed paste. |
| `:AgentSendBuffer` | Inject `@/abs/path` for saved buffers; paste current content for unsaved/modified ones. |
| `:AgentAsk <text>` | Inject arbitrary text and submit it directly to the agent. |

Injected code references are not submitted automatically. Review or extend the input in the agent terminal, then press Enter.

## Recommended Key Mappings

### Leader-key mappings

```vim
nmap <leader>aa <Plug>(agent-toggle)      " Toggle agent using the continue command
nmap <leader>an <Plug>(agent-new)         " Start a new session
xmap <leader>as <Plug>(agent-send)        " Send selected code
nmap <leader>ab <Plug>(agent-send-buffer) " Send the entire buffer
```

### Function-key mappings

The following example uses F12 to toggle the sidebar and Shift-F12 to start a new session. Shift-F12 is less likely than another bare function key to conflict with macOS system shortcuts:

```vim
" Normal editor windows
nmap <silent> <F12> <Plug>(agent-toggle)
nmap <silent> <S-F12> <Plug>(agent-new)

" Allow F12 to hide the sidebar while focus is inside the agent terminal
if has('nvim')
  tnoremap <silent> <F12> <C-\><C-N>:AgentToggle<CR>
else
  tnoremap <silent> <F12> <C-W>:AgentToggle<CR>
endif
```

If a function key does not work, verify that the mappings were loaded and were not overwritten by another plugin:

```vim
:verbose nmap <F12>
:verbose tmap <F12>
```

On macOS, F1–F12 may be handled as system media keys. Use `Fn+F12`, or configure macOS to use them as standard function keys.

### Browsing terminal history

When the agent terminal is in input mode, scrolling keys are usually handled by the CLI. Enter Terminal-Normal mode before browsing the Vim terminal buffer:

- Vim 8: press `Ctrl-W N`
- Neovim: press `Ctrl-\ Ctrl-N`
- `Ctrl-U` / `Ctrl-B`: scroll up half a page / one page
- `Ctrl-D` / `Ctrl-F`: scroll down half a page / one page
- `gg` / `G`: jump to the oldest / newest content
- Press `i` when finished to return to CLI input mode

Vim 8 can retain more terminal history with:

```vim
if exists('+termwinscroll')
  set termwinscroll=50000
endif
```

## Configuration

### Default command

```vim
" Compatible base command setting and its default value
let g:agent_command = 'ccagent --interactive'

" Terminal width; default: max([40, &columns*2/5])
let g:agent_width = 50
```

When no mode-specific environment variables are configured:

- `:AgentToggle!` runs `g:agent_command`
- A cold-started `:AgentToggle` runs `g:agent_command --continue`

### Separate new-session and continue commands

The plugin reads two complete startup commands from the Vim process environment:

| Environment variable | Operation |
|---|---|
| `AGENT_NEW_COMMAND` | Used by `:AgentToggle!`, which stops any existing sidebar process and starts a new session. |
| `AGENT_CONTINUE_COMMAND` | Used when `:AgentToggle` needs to start a process for continuing a session. |

If either variable is unset or empty, that mode falls back to the original behavior described above.

Add the variables to `~/.zshrc`, then open a new terminal or run `source ~/.zshrc`:

```zsh
export AGENT_NEW_COMMAND='ccagent --interactive'
export AGENT_CONTINUE_COMMAND='ccagent --interactive --continue'
```

Set the environment variables before starting Vim:

```zsh
source ~/.zshrc
vim README.md
```

Verify inside Vim that the variables were inherited:

```vim
:echo $AGENT_NEW_COMMAND
:echo $AGENT_CONTINUE_COMMAND
```

If Vim is launched from a graphical environment that does not load `~/.zshrc`, define the variables in `~/.vimrc` instead:

```vim
let $AGENT_NEW_COMMAND = 'ccagent --interactive'
let $AGENT_CONTINUE_COMMAND = 'ccagent --interactive --continue'
```

### Claude Code integration

```zsh
export AGENT_NEW_COMMAND='claude'
export AGENT_CONTINUE_COMMAND='claude --continue'
```

### Codex integration

```zsh
export AGENT_NEW_COMMAND='codex'
export AGENT_CONTINUE_COMMAND='codex resume --last'
```

Adjust the resume arguments for the Codex CLI version installed on your machine.

After choosing Claude, Codex, or another CLI, configure both `AGENT_NEW_COMMAND` and `AGENT_CONTINUE_COMMAND` for the new-session and continue modes of that same CLI. The plugin does not automatically switch between different CLIs; while a process is running, `:AgentToggle` only shows or hides it.

### Set extra environment variables in a command

Vim's `term_start()` does not interpret a leading `NAME=value` expression as a shell assignment. Use `env` instead:

```zsh
export AGENT_CONTINUE_COMMAND='env DP_P_INPUT=22.5 DP_P_OUT=45 DP_P_CACHE=1 ccagent --interactive --continue'
```

Do not append `$@`. These variables contain complete startup commands, not shell function definitions.

### Call functions defined in `~/.zshrc`

Given these functions in `~/.zshrc`:

```zsh
open_codex() {
  codex "$@"
}

open_claude() {
  claude --continue "$@"
}
```

Start an interactive zsh so that it loads the functions:

```zsh
export AGENT_NEW_COMMAND='zsh -ic open_codex'
export AGENT_CONTINUE_COMMAND='zsh -ic open_claude'
```

Do not configure only the function name, such as `AGENT_NEW_COMMAND='open_codex'`, because a zsh function is not a standalone executable.

Note: the C implementation of `ccagent` supports only `--interactive`; it does not provide the `-i` short option.

## Testing

```bash
# PTY smoke test covering terminal startup, injection, @ reference, toggling, and shutdown
python3 vim/test/smoke.py
```
