" 冒烟测试脚本（由 smoke.py 通过 vim -S 调用）
set nocompatible
let s:root = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:root)
runtime plugin/agent.vim
let g:agent_command = 'cat'
let g:agent_width = 40

" 准备一个已知内容的 buffer 用于 AgentSendBuffer
edit! /tmp/agent_vim_smoke_buf.sh
call setline(1, ['echo one', 'echo two'])
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

" 验证：注入文本首尾无泄漏按键（s:focus 的 feedkeys('i') 竞态会在末尾多一个 i，
" 冷启动 AgentToggle 同理会在开头多一个 i）。长引用行会被 40 列终端折行，
" 拼接所有行再检查，避免折行把 ）和 i 分到两行漏检。
let s:joined = join(s:lines, '')
let s:echo_ok = index(s:lines, 'hello-vim-agent') >= 0
let s:ref_ok = stridx(s:joined, 'ctx-') >= 0 && stridx(s:joined, '代码片段）i') < 0
call writefile([s:echo_ok && s:ref_ok ? 'noleak-ok' : 'noleak-fail'], '/tmp/agent_vim_smoke_noleak.out')

" 验证：进程退出后窗口自动关闭
" 注意：AgentSendBuffer 注入的引用文本不带回车，行缓冲非空时第一个 Ctrl-D
" 只是提交该行而非 EOF，所以先回车再 Ctrl-D
call term_sendkeys(bufnr('bash-agent'), "\<CR>\<C-D>")
sleep 1500m
call writefile([bufnr('bash-agent') > 0 ? 'alive' : 'closed'], '/tmp/agent_vim_smoke_exit.out')
qall!
