" 冒烟测试脚本（由 smoke.py 通过 vim -S 调用）
set nocompatible
let s:root = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:root)
runtime plugin/agent.vim
" 用无效的旧配置确保新会话和续聊实际由对应环境变量启动。
" 环境变量由 smoke.py 注入，模拟 Vim 继承 shell 环境。
let g:agent_command = 'agent-command-must-not-run'
let g:agent_width = 40

" 准备一个已知内容的 buffer 用于 AgentSendBuffer
" 先写文件落盘并 :edit，确保走 @/abs/path 引用分支（未落盘会退化为粘贴）
call writefile(['echo one', 'echo two'], '/tmp/agent_vim_smoke_buf.sh')
edit /tmp/agent_vim_smoke_buf.sh
set filetype=sh

AgentToggle!
sleep 1500m
AgentAsk hello-vim-agent
sleep 1500m
wincmd p
AgentSendBuffer
sleep 1000m
" 验证：AgentToggle 关闭（隐藏）窗口，再次 toggle 复用同一 buffer 重开
wincmd p
AgentToggle
let s:win_closed = bufwinnr('bash-agent') < 0
AgentToggle
let s:win_reopen = bufwinnr('bash-agent') > 0
call writefile([s:win_closed && s:win_reopen ? 'toggle-ok' : 'toggle-fail'], '/tmp/agent_vim_smoke_toggle.out')

" 把终端 buffer 内容导出
let s:lines = getbufline('bash-agent', 1, '$')
call writefile(s:lines, '/tmp/agent_vim_smoke.out')

" 验证：AgentSendBuffer 注入的 @ 引用不含尖括号、不带回车（cat 不会立刻回显第二行）。
" 长引用行会被 40 列终端折行，拼接所有行再检查；@path 之后紧跟 i 才算 focus 竞态泄漏。
let s:joined = join(s:lines, '')
let s:echo_ok = index(s:lines, 'hello-vim-agent') >= 0
let s:ref_ok = stridx(s:joined, '@/tmp/agent_vim_smoke_buf.sh') >= 0 && stridx(s:joined, '@/tmp/agent_vim_smoke_buf.shi') < 0
call writefile([s:echo_ok && s:ref_ok ? 'noleak-ok' : 'noleak-fail'], '/tmp/agent_vim_smoke_noleak.out')

" 验证：进程退出后窗口自动关闭
" 注意：AgentSendBuffer 注入的引用文本不带回车，行缓冲非空时第一个 Ctrl-D
" 只是提交该行而非 EOF，所以先回车再 Ctrl-D
call term_sendkeys(bufnr('bash-agent'), "\<CR>\<C-D>")
sleep 1500m
call writefile([bufnr('bash-agent') > 0 ? 'alive' : 'closed'], '/tmp/agent_vim_smoke_exit.out')

" 冷启动普通 AgentToggle，验证使用 AGENT_CONTINUE_COMMAND。
AgentToggle
sleep 1000m
call writefile([
      \ filereadable('/tmp/agent_vim_smoke_new_command') ? readfile('/tmp/agent_vim_smoke_new_command')[0] : 'missing-new',
      \ filereadable('/tmp/agent_vim_smoke_continue_command') ? readfile('/tmp/agent_vim_smoke_continue_command')[0] : 'missing-continue',
      \ ], '/tmp/agent_vim_smoke_commands.out')

" 两个环境变量为空时应回退到旧配置，并给续聊自动追加 --continue。
call agent#on_vim_leave()
let $AGENT_NEW_COMMAND = ''
let $AGENT_CONTINUE_COMMAND = ''
let g:agent_command = '/tmp/agent_vim_smoke_fallback.sh'
AgentToggle
sleep 1000m
qall!
