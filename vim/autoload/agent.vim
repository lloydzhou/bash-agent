" agent.vim — bash-agent 终端集成（路线 A：:terminal 常驻分屏）
" 布局：左侧编辑区，右侧 agent chat（VSCode 式）。
" 发送机制：
"   - AgentSend       把选中代码用 bracketed paste 直接灌进 agent 输入框
"   - AgentSendBuffer 已落盘且未修改的 buffer 注入 @/abs/path 引用（agent
"                     自行用 Read 工具读取）；否则退化为 AgentSend 粘贴内容
" 注入文本均不带回车，用户确认后自行按 Enter 提交。
" 兼容 vim8（term_start/term_sendkeys）与 neovim（termopen/chansend）。

let s:has_nvim = has('nvim')
let s:buf = -1          " agent 终端 buffer 号（-1 = 无）
let s:job = -1          " nvim job id（vim8 由 buffer 反查）
let s:mode = 'continue' " 启动模式：continue（追加 --continue 续聊）/ new（新会话）

" ---------- 配置 ----------

function! s:width() abort
  return get(g:, 'agent_width', max([40, &columns * 2 / 5]))
endfunction

function! s:command(mode) abort
  " 两个环境变量都是完整启动命令；非空时覆盖原有命令构建逻辑。
  " 未配置时保持兼容：g:agent_command（或默认值），续聊自动追加 --continue。
  let l:env_cmd = a:mode ==# 'new' ? $AGENT_NEW_COMMAND : $AGENT_CONTINUE_COMMAND
  if !empty(l:env_cmd)
    return l:env_cmd
  endif
  let l:cmd = get(g:, 'agent_command', 'ccagent --interactive')
  if a:mode ==# 'continue'
    let l:cmd .= ' --continue'
  endif
  return l:cmd
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

" 用 bracketed paste（ESC[200~ ... ESC[201~）包裹后注入。支持该协议的
" REPL（ccagent 的 linenoise / claude / codex 等）会把整段含换行的文本
" 作为一次粘贴并入输入缓冲，不逐行提交；不支持时标记字符会被原样回显，
" 但内容仍可见，agent 侧一般也能识别。vim8 term_sendkeys 把 <...> 解析
" 为特殊键，需把字面量 < 转成 <LT> 记法。
function! s:send_paste(text) abort
  let l:body = s:has_nvim ? a:text : substitute(a:text, '<', '<LT>', 'g')
  call s:send_raw("\x1b[200~" . l:body . "\x1b[201~")
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

" 把 [first, last] 范围的代码直接粘贴进 agent 输入框（不自动提交）。
" 注入格式：
"   /abs/path/to/file:first-last
"   <代码原文>
function! agent#send_range(first, last) abort
  if s:buf >= 0 && bufnr('%') == s:buf
    echoerr 'agent: 请在代码窗口执行 :AgentSend（当前在 agent 终端窗口）'
    return
  endif
  let l:path = expand('%:p')
  let l:header = empty(l:path)
        \ ? printf('[未命名 buffer]:%d-%d', a:first, a:last)
        \ : printf('%s:%d-%d', l:path, a:first, a:last)
  let l:text = l:header . "\n" . join(getline(a:first, a:last), "\n") . "\n"
  let l:reenter = s:in_term_normal()
  call s:ensure_running()
  call s:send_paste(l:text)
  call s:focus(l:reenter)
endfunction

" 优先用 @ 引用整个文件路径（agent 会自动用 Read 工具读取）；
" buffer 未落盘或已修改时退化为 send_range（粘贴当前内容，避免读到旧版本）。
function! agent#send_buffer() abort
  let l:path = expand('%:p')
  if !empty(l:path) && filereadable(l:path) && !&modified
    let l:reenter = s:in_term_normal()
    call s:ensure_running()
    call s:send_raw('@' . l:path)
    call s:focus(l:reenter)
    return
  endif
  call agent#send_range(1, line('$'))
endfunction

function! agent#ask(text) abort
  let l:reenter = s:in_term_normal()
  call s:ensure_running()
  call s:send_raw(a:text)
  call s:send_enter()
  call s:focus(l:reenter)
endfunction
