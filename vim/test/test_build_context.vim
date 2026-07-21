" headless 单测：vim -Nu NONE -n -es -S test_build_context.vim
" 结果写入 /tmp/agent_vim_test.out（PASS / FAIL）
set nocompatible
let s:root = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:root)

" 用一个已知路径的 scratch 文件
edit! /tmp/agent_vim_test_buf.sh
call setline(1, ['line A', 'line B', 'line C'])
set filetype=sh

let l:ctx = agent#build_context(2, 3)
let l:expect = "/tmp/agent_vim_test_buf.sh:2-3\n\n```sh\nline B\nline C\n```\n"

if l:ctx !=# l:expect
  call writefile(['FAIL', 'expect: ' . string(l:expect), 'got:    ' . string(l:ctx)], '/tmp/agent_vim_test.out')
  cquit!
endif

call writefile(['PASS'], '/tmp/agent_vim_test.out')
quit!
