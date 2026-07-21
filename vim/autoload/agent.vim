" agent.vim — bash-agent 终端集成（路线 A：:terminal 常驻分屏）
" 布局：左侧编辑区，右侧 agent chat（VSCode 式）。
" 发送机制：选中内容写入临时 .md 文件，只往 chat 输入行注入一行短引用文本
" （不带回车），用户接着输入问题后回车；agent 用 Read 工具读文件。
" 兼容 vim8（term_start/term_sendkeys）与 neovim（termopen/chansend）。

let s:has_nvim = has('nvim')
let s:buf = -1          " agent 终端 buffer 号（-1 = 无）
let s:job = -1          " nvim job id（vim8 由 buffer 反查）
let s:mode = 'continue' " 启动模式：continue（追加 --continue 续聊）/ new（新会话）
let s:seq = 0           " ctx 文件序号

" ---------- 配置 ----------

function! s:width() abort
  return get(g:, 'agent_width', max([40, &columns * 2 / 5]))
endfunction

function! s:command(mode) abort
  let l:cmd = get(g:, 'agent_command', 'ccagent --interactive')
  if a:mode ==# 'continue'
    let l:cmd .= ' --continue'
  endif
  return l:cmd
endfunction

function! s:ctx_dir() abort
  let l:tmp = empty($TMPDIR) ? '/tmp' : substitute($TMPDIR, '/$', '', '')
  return l:tmp . '/bash-agent-vim'
endfunction

function! s:ensure_ctx_dir() abort
  let l:dir = s:ctx_dir()
  if !isdirectory(l:dir)
    call mkdir(l:dir, 'p', 0700)
  endif
  return l:dir
endfunction

" ---------- 终端生命周期 ----------

function! s:alive() abort
  if s:buf < 0 || !bufexists(s:buf)
    return 0
  endif
  if s:has_nvim
    return s:job > 0
  endif
  try
    return job_status(term_getjob(s:buf)) ==# 'run'
  catch
    return 0
  endtry
endfunction

function! s:on_exit(...) abort
  let l:buf = s:buf
  let s:buf = -1
  let s:job = -1
  " 进程退出后自动关闭终端窗口（timer 延迟，回调上下文里直接关窗口可能报错）
  if l:buf > 0
    call timer_start(50, function('s:wipe_later', [l:buf]))
  endif
endfunction

function! s:wipe_later(buf, timer) abort
  if bufexists(a:buf)
    execute 'silent! bwipeout! ' . a:buf
  endif
endfunction

function! s:start(mode) abort
  let s:mode = a:mode
  if s:has_nvim
    execute 'botright vertical ' . s:width() . 'new'
    let s:buf = bufnr('%')
    let s:job = termopen(s:command(a:mode), {'on_exit': function('s:on_exit')})
  else
    let l:save_sr = &splitright
    set splitright
    let s:buf = term_start(s:command(a:mode), {
          \ 'term_name': 'bash-agent',
          \ 'vertical': 1,
          \ 'term_cols': s:width(),
          \ 'exit_cb': function('s:on_exit'),
          \ })
    let &splitright = l:save_sr
  endif
endfunction

function! s:show() abort
  " :sbuffer 不接受宽度计数（E16），先开窗再 resize
  execute 'botright vertical sbuffer ' . s:buf
  execute 'vertical resize ' . s:width()
endfunction

function! s:kill() abort
  if s:buf >= 0 && bufexists(s:buf)
    if s:has_nvim
      if s:job > 0
        silent! call jobstop(s:job)
      endif
    else
      try
        call job_stop(term_getjob(s:buf), 'kill')
      catch
      endtry
    endif
    execute 'silent! bwipeout! ' . s:buf
  endif
  let s:buf = -1
  let s:job = -1
endfunction

function! s:ensure_running() abort
  if s:alive()
    if bufwinnr(s:buf) < 0
      call s:show()
    endif
    return
  endif
  call s:kill()   " 清理死 buffer（若有）
  call s:start(s:mode)
endfunction

" ---------- 发送 ----------

" 注意：vim8 term_sendkeys 会把 <...> 解析为特殊键，注入文本请勿包含 '<'。
function! s:send_raw(text) abort
  if s:has_nvim
    call chansend(s:job, a:text)
  else
    call term_sendkeys(s:buf, a:text)
  endif
endfunction

function! s:send_enter() abort
  if s:has_nvim
    call chansend(s:job, "\r")
  else
    call term_sendkeys(s:buf, "\<CR>")
  endif
endfunction

" reenter: 调用本函数前是否已经坐在终端窗口且处于 Terminal-Normal 模式
" （Ctrl-W N 翻历史后）。只有这种情况才需要手动 feedkeys('i') 回到输入模式。
" 刚从别的窗口切进来时 Vim 会在命令结束后自动进入 Terminal-Job 模式，此时
" 若提前把 i 排进输入队列，i 会被当成普通按键发给 CLI（注入文本末尾多出 i）。
function! s:focus(reenter) abort
  let l:win = bufwinnr(s:buf)
  if l:win < 0
    return
  endif
  execute l:win . 'wincmd w'
  if s:has_nvim
    startinsert
  elseif a:reenter
    call feedkeys('i', 'n')   " Terminal-Normal → Terminal-Job
  endif
endfunction

" 调用方入口处捕获：当前是否正坐在 agent 终端窗口的 Terminal-Normal 模式里
function! s:in_term_normal() abort
  return !s:has_nvim && s:buf >= 0 && bufnr('%') == s:buf && mode() ==# 'n'
endfunction

" ---------- 上下文构建（公共函数，便于 headless 单测） ----------

function! agent#build_context(first, last) abort
  let l:header = printf('%s:%d-%d', expand('%:p'), a:first, a:last)
  let l:body = join(['```' . &filetype] + getline(a:first, a:last) + ['```'], "\n")
  return l:header . "\n\n" . l:body . "\n"
endfunction

function! s:write_ctx(content) abort
  let s:seq += 1
  let l:file = printf('%s/ctx-%d-%d.md', s:ensure_ctx_dir(), localtime(), s:seq)
  call writefile(split(a:content, "\n", 1), l:file)
  return l:file
endfunction

" ---------- 公共 API ----------

" vim 退出前杀掉 agent job 并清掉终端 buffer。
" 不做的话，隐藏的 agent 终端里 job 还在跑，:qall 会被 E947
" （Job still running in buffer）拦住，得先退出 CLI 才能退出 vim。
" CLI 会话存在磁盘上（--continue 恢复），杀 REPL 进程不丢聊天历史。
function! agent#on_vim_leave() abort
  if s:buf >= 0 && bufexists(s:buf)
    call s:kill()
  endif
endfunction

" mode: 'continue'（默认，续聊）/ 'new'（新会话）
function! agent#toggle(mode) abort
  if a:mode ==# 'new' && s:alive()
    call s:kill()
  endif
  let l:win = s:buf >= 0 ? bufwinnr(s:buf) : -1
  if l:win >= 0
    " 终端 buffer 带运行中的 job 算“已修改”，nohidden 下 :close 会报 E37，用 close! 强制隐藏
    execute l:win . 'close!'
    return
  endif
  let l:reenter = s:in_term_normal()
  if s:alive()
    call s:show()
  else
    call s:kill()
    call s:start(a:mode)
  endif
  call s:focus(l:reenter)
endfunction

function! agent#send_range(first, last) abort
  if s:buf >= 0 && bufnr('%') == s:buf
    echoerr 'agent: 请在代码窗口执行 :AgentSend（当前在 agent 终端窗口）'
    return
  endif
  let l:file = s:write_ctx(agent#build_context(a:first, a:last))
  let l:ref = printf('看 %s（%s:%d-%d 的代码片段）', l:file, expand('%:t'), a:first, a:last)
  let l:reenter = s:in_term_normal()
  call s:ensure_running()
  call s:send_raw(l:ref)
  call s:focus(l:reenter)
endfunction

function! agent#send_buffer() abort
  call agent#send_range(1, line('$'))
endfunction

function! agent#ask(text) abort
  let l:reenter = s:in_term_normal()
  call s:ensure_running()
  call s:send_raw(a:text)
  call s:send_enter()
  call s:focus(l:reenter)
endfunction
