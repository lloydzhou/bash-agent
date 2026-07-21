" agent.vim — bash-agent 终端集成（:terminal 常驻分屏）
if exists('g:loaded_agent_vim') || &compatible
  finish
endif
let g:loaded_agent_vim = 1

" :AgentToggle   续聊模式（默认追加 --continue）；已在运行则隐藏/显示
" :AgentToggle!  新会话（不追加 --continue）；已在运行则杀掉重启
command! -bang AgentToggle call agent#toggle(<bang>0 ? 'new' : 'continue')
command! -range AgentSend call agent#send_range(<line1>, <line2>)
command! AgentSendBuffer call agent#send_buffer()
command! -nargs=+ AgentAsk call agent#ask(<q-args>)

nnoremap <silent> <Plug>(agent-toggle) :<C-U>AgentToggle<CR>
nnoremap <silent> <Plug>(agent-new) :<C-U>AgentToggle!<CR>
xnoremap <silent> <Plug>(agent-send) :AgentSend<CR>
nnoremap <silent> <Plug>(agent-send-buffer) :<C-U>AgentSendBuffer<CR>

" 退出 vim 前清理 agent 终端，避免隐藏的 CLI job 阻塞 :qall（E947）
augroup agent_vim
  autocmd!
  autocmd VimLeavePre * call agent#on_vim_leave()
augroup END
