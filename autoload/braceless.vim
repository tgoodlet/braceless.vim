" I had it in my head that blocks needed to stop when they hit another pattern
" match. They just need to stop at lower-indented lines.  I could hard-code
" the stop pattern, but I don't want to break the magic spell that's making
" this work.
let s:cpo_save = &cpo
set cpo&vim

" The cache of found patterns
let s:pattern_cache = {}


" Default patterns
let s:pattern_default = {}
let s:pattern_default.python = {
      \   'start': '\%(if\|def\|for\|try\|elif\|else\|with\|class\|while\|except\|finally\)\_.\{-}:\ze\s*\%(\_$\|#\)',
      \   'end': '\S',
      \}
let s:pattern_default.coffee = {
      \   'start': '\%('
      \             .'\%(\zs\%(do\|if\|for\|try\|else\|when\|with\|catch\|class\|while\|switch\|finally\).*\)\|'
      \             .'\S\&.\+\%('
      \               .'\zs(.*)\s*[-=]>'
      \               .'\|\((.*)\s*\)\@<!\zs[-=]>'
      \               .'\|\zs=\_$'
      \           .'\)\).*',
      \   'end': '\S',
      \}

" Coffee Script is tricky as hell to match.  Explanation of above:
" - Start an atom that groups everything, so that searchpos() will match the
"   entire line.
"   - Match block keywords
"   - Start an atom that matches symbols that start a block
"     - Match a splat with arguments to position at the beginning of the
"     arguments
"     - Match a splat without arguments.  Explicitly don't match splat with
"     arguments, since it would technically match.
"     - An equal sign at the end of a line
" - Close the atoms


" Get the indented block by finding the first line that matches a pattern that
" looks for a lower indent level.
function! s:get_block_end(start, pattern)
  let end = line('$')
  let start = min([end, a:start])
  let lastline = end

  while start > 0 && start <= end
    if getline(start) =~ a:pattern && !braceless#is_string(start)
      let lastline = braceless#prevnonstring(start - 1)
      break
    endif
    let start = nextnonblank(start + 1)
  endwhile

  return prevnonblank(lastline)
endfunction


" Special case block.  Finds a line that followed by a blank line.
function! s:get_block_until_blank(start)
  let end = line('$')
  let start = min([end, a:start])
  let lastline = end

  while start > 0 && start <= end
    if getline(start + 1) =~ '^$' && !braceless#is_string(start)
      let lastline = braceless#prevnonstring(start)
      break
    endif
    let start = nextnonblank(start + 1)
  endwhile

  return lastline
endfunction


" Build a pattern that is suitable for the current line and indent level
function! s:build_pattern(line, base, ...)
  let pat = '^\s*'.a:base
  let ignore_empty = 0
  if a:0 != 0
    let ignore_empty = a:1
  endif

  let flag = 'bc'
  let text = getline(a:line)

  let indent_delta = 0
  let indent_line = a:line
  if text =~ '^\s*$'
    let indent_delta = -1
  else
    " motions can get screwed up if initiated from within a docstring
    " that's under indented.
    if braceless#is_string(a:line)
      let docstring = braceless#docstring(a:line)
      if docstring[0] != 0
        let indent_line = docstring[0]
      endif
    endif

    " Try matching a multi-line block start
    " The window state should be saved before this, so no need to restore
    " the curswant
    let pos = getpos('.')
    call cursor(indent_line, col([indent_line, '$']))
    let pos2 = getpos('.')
    let head = searchpos(pat, 'cbW')
    let tail = searchpos(pat, 'ceW')
    call setpos('.', pos)
    if tail[0] == pos2[1] || head[0] == pos2[1]
      let indent_line = head[0]
      let indent_delta = 0
      " Move to the head line
      call setpos('.', pos2)
    else
      let indent_delta = -1
    endif
  endif

  let [indent_char, indent_len] = braceless#indent#space(indent_line, indent_delta)

  " Even though we found the indent level of a block, make sure it has a
  " body.  If it doesn't, lower the indent level by one.
  if !ignore_empty && getline(indent_line) =~ '^\s*'.a:base
    let nextline = nextnonblank(indent_line + 1)
    let [_, indent_len2] = braceless#indent#space(nextline, indent_delta)
    if indent_len >= indent_len2
      let [_, indent_len] = braceless#indent#space(indent_line, indent_delta - 1)
    endif
  endif

  let pat = '^'.indent_char.'\{-,'.indent_len.'}'

  if a:base !~ '\\zs'
    let pat .= '\zs'
  endif
  let pat .= a:base

  return [pat, flag]
endfunction


" Get the line with the nicest looking indent level
function! s:best_indent(line)
  let p_line = prevnonblank(a:line)
  let n_line = nextnonblank(a:line)

  " Make sure there's at least something to find
  if p_line == 0
    return 0
  endif

  let p_indent = indent(p_line)
  let n_indent = indent(n_line)

  " If the current line is all whitespace, use one of the surrounding
  " non-empty line's indent level that you may expect to be the selected
  " block.
  if getline(a:line) =~ '^\s*$'
    if p_indent > n_indent
      return n_line
    endif

    return p_line
  endif

  return a:line
endfunction


let s:syn_string = '\%(String\|Heredoc\|DoctestValue\|DocTest\|DocTest2\)$'
let s:syn_comment = '\%(Comment\|Todo\)$'

function! braceless#is_string(line, ...)
  return synIDattr(synID(a:line, a:0 ? a:1 : col([a:line, '$']) - 1, 1), 'name') =~ s:syn_string
        \ && (a:0 || synIDattr(synID(a:line, 1, 1), 'name') =~ s:syn_string)
endfunction


function! braceless#is_comment(line, ...)
  return synIDattr(synID(a:line, a:0 ? a:1 : col([a:line, '$']) - 1, 1), 'name') =~ s:syn_comment
        \ && (a:0 || synIDattr(synID(a:line, 1, 1), 'name') =~ s:syn_comment)
endfunction


function! braceless#prevnonstring(line)
  let l = prevnonblank(a:line)
  while l > 0
    if !braceless#is_string(l)
      return l
    endif
    let l = prevnonblank(l - 1)
  endwhile

  return l
endfunction


let s:docstr = '\%("""\|''''''\)'
" Returns the start and end lines for docstrings
" Couldn't get this to work reliably using searches.
function! braceless#docstring(line, ...)
  let l = nextnonblank(a:line)
  let doc_head = 0
  let doc_tail = 0

  let bounds = a:0 ? a:1 : [1, line('$')]

  while l >= bounds[0]
    if getline(l) =~ s:docstr && braceless#is_string(nextnonblank(l + 1))
      let doc_head = l
      break
    elseif !braceless#is_string(l)
      break
    endif
    let l = prevnonblank(l - 1)
  endwhile

  if doc_head == 0
    return [0, 0]
  endif

  let l = prevnonblank(a:line)
  while l <= bounds[1]
    if getline(l) =~ s:docstr && braceless#is_string(prevnonblank(l - 1))
      let doc_tail = l
      break
    elseif !braceless#is_string(l)
      break
    endif
    let l = nextnonblank(l + 1)
  endwhile

  return [doc_head, doc_tail]
endfunction


" Scans for a block head by making sure the cursor doesn't land in a string or
" comment that looks like a block head.  This moves the cursor.
function! braceless#scan_head(pat, flag)
  let head = searchpos(a:pat, a:flag.'W')
  let shit_guard = 5
  while shit_guard > 0 && head[0] != 0
    if braceless#is_string(head[0], head[1]) || braceless#is_comment(head[0], head[1])
      let head = searchpos(a:pat, a:flag.'W')
      let shit_guard -= 1
      continue
    endif
    break
  endwhile
  return head
endfunction


" Scan for a block tail by making sure it doesn't land a string or comment.
" This does not move the cursor.
function! braceless#scan_tail(pat, head)
  let tail = searchpos(a:pat, 'nceW')
  " To deal with shitty multiline block starts.  This is an issue for Python
  " where function arguments can be interrupted with comments or have default
  " values which may be a string that looks like the end of the block start.
  " Note: This feels dumb.
  if match(a:pat, '\\_\.\\{-}') != -1
    let shit_guard = 0
    let head_byte = line2byte(a:head[0]) + a:head[1]

    let shit_guard = 5
    while shit_guard > 0 && tail[0] != 0
      let shit_guard -= 1

      if braceless#is_string(tail[0], tail[1]) || braceless#is_comment(tail[0], tail[1])
        " If the tail ends up a string or comment, replace the \_.\{-} portion
        " of the pattern with one that specifically skips a certain amount of
        " characters from the start of the head.
        let tail_byte = line2byte(tail[0]) + tail[1]
        let tail_tail = '\\_\.\\{-'.(tail_byte - head_byte).',}'
        let tail = searchpos(substitute(a:pat, '\\_\.\\{-}', tail_tail, ''), 'nceW')
        continue
      endif
      break
    endwhile
  endif

  return tail
endfunction


" Select an indent block using ~magic~
function! braceless#select_block(pattern, ...)
  let ignore_empty = 0
  if a:0 != 0
    let ignore_empty = a:1
  endif

  let saved_view = winsaveview()
  let c_line = s:best_indent(line('.'))
  if c_line == 0
    return 0
  endif

  let [pat, flag] = s:build_pattern(c_line, a:pattern.start, ignore_empty)

  let head = braceless#scan_head(pat, flag)
  let tail = braceless#scan_tail(pat, head)

  if head[0] == 0 || tail[0] == 0
    call winrestview(saved_view)
    return [c_line, c_line, head[0], tail[0]]
  endif

  " Finally begin the block search
  let head = searchpos(pat, 'cbW')

  let [indent_char, indent_len] = braceless#indent#space(head[0], 0)
  let pat = '^'.indent_char.'\{,'.indent_len.'}'.a:pattern.stop

  let startline = nextnonblank(tail[0] + 1)
  let lastline = s:get_block_end(startline, pat)

  call winrestview(saved_view)

  if lastline < startline
    return [lastline, lastline, head[0], tail[0]]
  endif

  return [head[0], lastline, head[0], tail[0]]
endfunction


" Gets a pattern.  If g:braceless#pattern#<filetype> does not exist, fallback to
" a built in one, and if that doesn't exist, use basic matching
function! braceless#get_pattern(...)
  let lang = &ft
  if a:0 > 0 && type(a:1) == 1
    let lang = a:1
  endif

  if !has_key(s:pattern_cache, lang)
    let pat = get(g:, 'braceless#pattern#'.lang, {})
    let def = get(s:pattern_default, lang, {})
    let start_pat = get(pat, 'start', get(def, 'start', '\S.*'))
    let stop_pat = get(pat, 'stop', get(def, 'stop', '\S'))
    let s:pattern_cache[lang] = {
          \   'start': start_pat,
          \   'stop': stop_pat,
          \   'jump': get(pat, 'jump', get(def, 'jump', start_pat)),
          \   'easymotion': get(pat, 'easymotion', get(def, 'easymotion', start_pat)),
          \ }
  endif
  return get(s:pattern_cache, lang)
endfunction


" Define a pattern directly with reckless abandon.  If a:patterns is not a
" dict, the a:filetype item will be removed from the cache.
function! braceless#define_pattern(filetype, patterns)
  if type(patterns) != 4 && has_key(s:pattern_cache, a:filetype)
    unlet s:pattern_cache[a:filetype]
    return
  endif

  let s:pattern_cache[a:filetype] = a:patterns
endfunction


" Gets the lines involved in a block without selecting it
function! braceless#get_block_lines(line, ...)
  let pattern = braceless#get_pattern()
  let saved = winsaveview()
  let ignore_empty = 0
  if a:0 != 0
    let ignore_empty = a:1
  endif
  call cursor(a:line, col([a:line, '$']))
  let block = braceless#select_block(pattern, ignore_empty)
  call winrestview(saved)
  if type(block) != 3
    return
  endif

  let prev_line = prevnonblank(block[0])
  let next_line = nextnonblank(block[0])
  if indent(next_line) < indent(prev_line)
    let block[0] = prev_line
  else
    let block[0] = next_line
  endif

  return block
endfunction


function! braceless#get_parent_block_lines(line, ...)
  let saved = winsaveview()
  let block = braceless#get_block_lines(a:line)
  let [indent_char, indent_len] = braceless#indent#space(block[2], -1)
  call cursor(block[2], 0)
  let sub = search('^'.indent_char.'{-,'.indent_len.'}\S', 'nbW')
  let parent = braceless#get_block_lines(sub)
  call winrestview(saved)
  return [parent, block]
endfunction


let &cpo = s:cpo_save
unlet s:cpo_save
