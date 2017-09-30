
let s:max_columns = exists('g:rcsv_max_columns') ? g:rcsv_max_columns : 30
let s:rainbowStorage = $HOME . '/.rainbow_csv_storage'
let s:rainbowSettingsPath = $HOME . '/.rainbow_csv_files'

let s:script_folder_path = fnamemodify(resolve(expand('<sfile>:p')), ':h')
let s:python_env_initialized = 0
let s:system_python_interpreter = ''

let s:magic_chars = '^*$.~/[]\'

func! s:is_rainbow_table()
    return exists("b:rainbow_csv_delim")
endfunc


func! s:get_meta_language()
    if exists("g:rbql_meta_language")
        let lang_lw = tolower(g:rbql_meta_language)
        if lang_lw == 'javascript'
            let lang_lw = 'js'
        endif
        return lang_lw
    endif
    return "python"
endfunc


func! s:create_recurrent_tip(tip_text)
    let b:rb_tip_text = a:tip_text
    augroup RainbowHintGrp
        autocmd! CursorHold <buffer>
        autocmd CursorHold <buffer> echo b:rb_tip_text
    augroup END
    redraw!
    echo a:tip_text
endfunc


function! s:InvertMap(pairs)
    let i = 0
    while i < len(a:pairs)
        let tmpv = a:pairs[i][0]
        let a:pairs[i][0] = a:pairs[i][1]
        let a:pairs[i][1] = tmpv
        let i += 1
    endwhile
    return a:pairs
endfunction


function! s:ListExistingBufDirs()
    let buff_ids = filter(range(1, bufnr('$')), 'buflisted(v:val)')
    let dirs_weights = {}
    let dirs_weights[getcwd()] = 1000000
    let home_dir = $HOME
    let dirs_weights[home_dir] = 10000
    for buff_id in buff_ids
        let buff_dir = expand("#" . buff_id . ":p:h")
        let weight = 1
        if !has_key(dirs_weights, buff_dir)
            let dirs_weights[buff_dir] = 0
        endif
        if len(getbufvar(buff_id, "selected_buf"))
            let weight = 100
        endif
        let dirs_weights[buff_dir] += weight
    endfor
    let ranked = sort(s:InvertMap(items(dirs_weights)))
    let ranked = reverse(ranked)
    let result = []
    for rr in ranked
        call add(result, rr[1])
    endfor
    return result
endfunction


func! rainbow_csv#save_and_swap(dst_path)
    execute "bd " . b:parent_buf_nr
    call rename(b:parent_path, a:dst_path)
    execute "e " . a:dst_path
endfunction


func! rainbow_csv#dbg_set_system_python_interpreter(interpreter)
    let s:system_python_interpreter = a:interpreter
endfunction


func! s:SelectDirectory()
    let line = getline('.')
    call feedkeys(":RbSaveAndSwap " . line . "/")
endfunction


func! rainbow_csv#create_save_dialog(table_buf_nr, table_path)
    enew
    setlocal buftype=nofile
    setlocal modifiable
    setlocal noswapfile
    setlocal nowrap

    setlocal nonumber
    setlocal cursorline
    setlocal nobuflisted

    setlocal bufhidden=delete

    let b:parent_buf_nr = a:table_buf_nr
    let b:parent_path = a:table_path

    let existing_dirs = s:ListExistingBufDirs()
    call setline(1, "Select target directory, press Enter, and complete the command:")
    call setline(2, "")
    for nf in range(len(existing_dirs))
        call setline(nf + 3, existing_dirs[nf])
    endfor
    call cursor(3, 1)
    echo "Select target directory and press Enter"
    redraw!
    setlocal nomodifiable
    nnoremap <buffer> <CR> :call <SID>SelectDirectory()<CR>
endfunction


func! rainbow_csv#find_python_interpreter()
    "checking `python3` first, because `python` could be theorethically linked to python 2.6
    let py3_version = tolower(system('python3 --version'))
    if (v:shell_error == 0 && match(py3_version, 'python 3\.') == 0)
        let s:system_python_interpreter = 'python3'
        return s:system_python_interpreter
    endif
    let py_version = tolower(system('python --version'))
    if (v:shell_error == 0 && (match(py_version, 'python 2\.7') == 0 || match(py_version, 'python 3\.') == 0))
        let s:system_python_interpreter = 'python'
        return s:system_python_interpreter
    endif
    let s:system_python_interpreter = ''
    return s:system_python_interpreter
endfunc


function! s:py_source_escape(src)
    let dst = substitute(a:src, '\\', '\\\\', "g")
    let dst = substitute(dst, '\t', '\\t', "g")
    return dst
endfunc


function! s:char_class_escape(src)
    if a:src == ']'
        return '\]'
    endif
    if a:src == '\'
        return '\\'
    endif
    return a:src
endfunc


function! s:EnsurePythonInitialization()
    if (s:python_env_initialized)
        return 1
    endif
    let py_home_dir = fnamemodify(s:script_folder_path . '/../python', ":p")
    let py_home_dir = s:py_source_escape(py_home_dir)
    if has("python3")
        py3 import sys
        py3 import vim
        exe 'python3 sys.path.insert(0, "' . py_home_dir . '")'
        py3 import vim_rbql
    elseif has("python")
        py import sys
        py import vim
        exe 'python sys.path.insert(0, "' . py_home_dir . '")'
        py import vim_rbql
    else
        call rainbow_csv#find_python_interpreter()
        if s:system_python_interpreter == ""
            return 0
        endif
    endif
    let s:python_env_initialized = 1
    return 1
endfunction


func! s:ensure_storage_exists()
    if !isdirectory(s:rainbowStorage)
        call mkdir(s:rainbowStorage, "p")
    endif
endfunc


func! rainbow_csv#rstrip(line)
    let result = a:line
    if len(result) && result[len(result) - 1] == "\n"
        let result = strpart(result, 0, len(result) - 1)
    endif
    if len(result) && result[len(result) - 1] == "\r"
        let result = strpart(result, 0, len(result) - 1)
    endif
    return result
endfunc


func! rainbow_csv#preserving_escaped_split(line)
    let src = a:line
    if stridx(src, '"') == -1
        "Optimization for majority of lines
        return split(src, ',', 1)
    endif
    let result = []
    let cidx = 0
    while cidx < len(src)
        if src[cidx] == '"'
            let uidx = cidx + 1
            while 1
                let uidx = stridx(src, '"', uidx)
                if uidx == -1
                    call add(result, strpart(src, cidx))
                    return result
                elseif uidx + 1 >= len(src) || src[uidx + 1] == ','
                    call add(result, strpart(src, cidx, uidx + 1 - cidx))
                    let cidx = uidx + 2
                    break
                elseif src[uidx + 1] == '"'
                    let uidx += 2
                    continue
                else
                    let uidx += 1
                    continue
                endif
            endwhile
        else
            let uidx = stridx(src, ',', cidx)
            if uidx == -1
                let uidx = len(src)
            endif
            let field = strpart(src, cidx, uidx - cidx)
            call add(result, field)
            let cidx = uidx + 1
        endif
    endwhile
    if src[len(src) - 1] == ','
        call add(result, '')
    endif
    return result 
endfunc


func! s:preserving_smart_split(line, dlm)
    let stripped = rainbow_csv#rstrip(a:line)
    if a:dlm == ','
        return rainbow_csv#preserving_escaped_split(stripped)
    else
        return split(stripped, a:dlm, 1)
    endif
endfunc


func! s:lines_are_delimited(lines, delim)
    let num_fields = len(s:preserving_smart_split(a:lines[0], a:delim))
    if (num_fields < 2 || num_fields > s:max_columns)
        return 0
    endif
    for line in a:lines
        let nfields = len(s:preserving_smart_split(line, a:delim))
        if (num_fields != nfields)
            return 0
        endif
    endfor
    return 1
endfunc


func! s:auto_detect_delimiter(delimiters)
    let lastLineNo = min([line("$"), 10])
    if (lastLineNo < 5)
        return ''
    endif
    let sampled_lines = []
    for linenum in range(1, lastLineNo)
        call add(sampled_lines, getline(linenum))
    endfor
    for delim in a:delimiters
        if (s:lines_are_delimited(sampled_lines, delim))
            return delim
        endif
    endfor
    return ''
endfunc


let s:pairs = [['darkred', 'darkred'], ['darkblue', 'darkblue'], ['darkgreen', 'darkgreen'], ['darkmagenta', 'darkmagenta'], ['darkcyan', 'darkcyan'], ['red', 'red'], ['blue', 'blue'], ['green', 'green'], ['magenta', 'magenta'], ['NONE', 'NONE']]


let s:pairs = exists('g:rcsv_colorpairs') ? g:rcsv_colorpairs : s:pairs
let s:delimiters = ['	', ',']
let s:delimiters = exists('g:rcsv_delimiters') ? g:rcsv_delimiters : s:delimiters


func! s:rstrip(src)
    return substitute(a:src, '\s*$', '', '')
endfunc


func! s:read_column_names()
    let fname = expand("%:p")
    let headerName = fname . '.header'

    let setting_lines = s:read_settings()
    for line in setting_lines
        let fields = split(line, "\t")
        if fields[0] == fname && len(fields) >= 3
            let headerName = fields[2]
            break
        endif
    endfor

    if (!filereadable(headerName))
        return []
    endif
    let lines = readfile(headerName, '', 1)
    if (!len(lines))
        return []
    endif
    let line = lines[0]
    let names = split(line, b:rainbow_csv_delim)
    return names
endfunc


func! rainbow_csv#clear_current_buf_content()
    let nl = line("$")
    call cursor(1, 1)
    execute "delete " . nl
endfunc


func! s:single_char_sring(string_len, string_char)
    let result = ''
    for ii in range(a:string_len)
        let result = result . a:string_char
    endfor
    return result
endfunc


func! rainbow_csv#generate_tab_statusline(tabstop_val, template_fields)
    let result = []
    let space_deficit = 0
    for nf in range(len(a:template_fields))
        let available_space = (1 + len(a:template_fields[nf]) / a:tabstop_val) * a:tabstop_val
        let column_name = 'a' . string(nf + 1)
        let extra_len = available_space - len(column_name) - 1
        if extra_len < 0
            let space_deficit -= extra_len
            let extra_len = 0
        else
            let regained = min([space_deficit, extra_len])
            let space_deficit -= regained
            let extra_len -= regained
        endif
        let space_filling = s:single_char_sring(1 + extra_len, ' ')
        if nf + 1 == len(a:template_fields)
            let space_filling = ''
        endif
        call add(result, column_name)
        call add(result, space_filling)
    endfor
    return result
endfunc




func! s:status_escape_string(src)
    let result = substitute(a:src, ' ', '\\ ', 'g')
    let result = substitute(result, '"', '\\"', 'g')
    return result
endfunc


func! rainbow_csv#restore_statusline()
    if !exists("b:statusline_before")
        return
    endif
    augroup StatusDisableGrp
        autocmd!
    augroup END
    let escaped_statusline = s:status_escape_string(b:statusline_before)
    execute "set statusline=" . escaped_statusline
    unlet b:statusline_before
endfunc


func! rainbow_csv#set_statusline_columns()
    if !s:is_rainbow_table()
        return
    endif
    if !exists("b:statusline_before")
        let b:statusline_before = &statusline 
    endif
    let delim = b:rainbow_csv_delim
    let has_number_column = &number
    "TODO take "sign" column into account too. You can use :sign place buffer={nr}
    let indent = ''
    if has_number_column
        let indent_len = max([len(string(line('$'))) + 1, 4])
        let indent = s:single_char_sring(indent_len, ' ')
    endif
    let bottom_line = getline(line('w$'))
    let bottom_fields = s:preserving_smart_split(bottom_line, delim)
    let status_labels = []
    if delim == "\t"
        let status_labels = rainbow_csv#generate_tab_statusline(&tabstop, bottom_fields)
    else
        let status_labels =  rainbow_csv#generate_tab_statusline(1, bottom_fields)
    endif
    let max_len = winwidth(0)
    let cur_len = len(indent)
    let rb_statusline = '%#status_line_default_hl#' . indent
    let num_columns = len(status_labels) / 2
    for nf in range(num_columns)
        let color_id = nf % 10
        let column_name = status_labels[nf * 2]
        let space_filling = status_labels[nf * 2 + 1]
        let cur_len += len(column_name) + len(space_filling)
        if cur_len + 1 >= max_len 
            break
        endif
        let rb_statusline = rb_statusline . '%#status_color' . color_id . '#' . column_name . '%#status_line_default_hl#' . space_filling
    endfor
    let rb_statusline = s:status_escape_string(rb_statusline)
    execute "set statusline=" . rb_statusline
    augroup StatusDisableGrp
        autocmd CursorHold * call rainbow_csv#restore_statusline()
        autocmd CursorMoved * call rainbow_csv#restore_statusline()
        autocmd WinEnter * call rainbow_csv#restore_statusline()
        autocmd WinLeave * call rainbow_csv#restore_statusline()
    augroup END
    redraw!
endfunc


func! s:get_rb_script_path_for_this_table()
    let rb_script_name = expand("%:t") . ".rb"
    call s:ensure_storage_exists()
    let rb_script_path = s:rainbowStorage . '/' . rb_script_name
    let already_exists = filereadable(rb_script_path)
    if already_exists
        call delete(rb_script_path)
    endif
    return rb_script_path
endfunc


func! s:generate_microlang_syntax(nfields)
    let npairs = len(s:pairs)
    if (npairs < 2)
        return
    endif

    if s:get_meta_language() == "python"
        set ft=python
    else
        set ft=javascript
    endif

    for pn in range(npairs)
        let cmd = 'highlight rbql_color%d ctermfg=%s guifg=%s'
        exe printf(cmd, pn + 1, s:pairs[pn][0], s:pairs[pn][1])
    endfor

    for lnum in range(1, a:nfields)
        let color_num = ((lnum - 1) % npairs) + 1
        let cmd = 'syntax keyword rbql_color%d a%d'
        exe printf(cmd, color_num, lnum)
    endfor

    highlight RbCmd ctermbg=blue guibg=blue
    syntax keyword RbCmd UPDATE SELECT WHERE INITIALIZE DESC ASC
    syntax keyword RbCmd update select where initialize desc asc
    syntax match RbCmd "ORDER BY"
    syntax match RbCmd "order by"
    syntax match RbCmd "INNER JOIN"
    syntax match RbCmd "inner join"
    syntax match RbCmd "LEFT JOIN"
    syntax match RbCmd "left join"
    syntax match RbCmd "STRICT LEFT JOIN"
    syntax match RbCmd "strict left join"
endfunc


func! s:make_select_line(num_fields)
    let select_line = 'select '
    let new_rows = []
    for nf in range(1, a:num_fields)
        let select_line = select_line . 'a' . nf
        if nf < a:num_fields
            let select_line = select_line . ', '
        endif
    endfor
    return select_line
endfunc


func! s:make_javascript_demo(num_fields)
    let select_line = s:make_select_line(a:num_fields)

    let help_before = []
    call add(help_before, '// Welcome to RBQL: SQL with JavaScript or Python expressions.')
    call add(help_before, '// To use RBQL with Python expressions see instructions at the bottom.')
    call add(help_before, '')
    call add(help_before, '// "a1", "a2", etc are column names.')
    call add(help_before, '// You can use them in JavaScript expressions, e.g. "a1 * 20 + a2.length * Math.random()"')
    call add(help_before, '// To run the query press F5.')
    call add(help_before, '// For more info visit https://github.com/mechatroner/rainbow_csv')
    call add(help_before, '')
    call add(help_before, '')
    call add(help_before, '// modify:')
    call add(help_before, select_line)
    call setline(1, help_before)
    let help_after = []
    call add(help_after, '')
    call add(help_after, '// To join with another table, modify this:')
    call add(help_after, '//join /path/to/another/table.tsv on a2 == b1')
    call add(help_after, '')
    call add(help_after, '// To filter result set, modify this:')
    call add(help_after, '//where a1.length > 10')
    call add(help_after, '')
    call add(help_after, '// To sort result set, modify this:')
    call add(help_after, '//order by a2 desc')
    call add(help_after, '')
    call add(help_after, '')
    call add(help_after, '')
    call add(help_after, '// Examples of RBQL queries:')
    call add(help_after, '// select * where a1 == "SELL"')
    call add(help_after, '// select a4, a1')
    call add(help_after, '// select * order by parseInt(a2) desc')
    call add(help_after, '// select * order by Math.random()')
    call add(help_after, '// select NR, * where NR <= 100')
    call add(help_after, '// select distinct a1, *, 200, parseInt(a2) + 5, "hello world" where NR > 100 and a5 < -7 order by a3 ASC')
    call add(help_after, '')
    call add(help_after, '// Next time you can run another query by entering it into vim command line starting with ":Select" command.')
    call add(help_after, '')
    call add(help_after, '')
    call add(help_after, '')
    call add(help_after, '// =======================================================================================')
    call add(help_after, '// Instructions for Python:')
    call add(help_after, '// 1. Add "let g:rbql_meta_language = ''python''" to your .vimrc')
    call add(help_after, '// 2. Execute ":let g:rbql_meta_language = ''python''"')
    call add(help_after, '// 3. Exit this buffer and run F5 again')
    call setline(1 + len(help_before), help_after)
    call cursor(len(help_before), 1)
    w
endfunc


func! s:make_python_demo(num_fields)
    let select_line = s:make_select_line(a:num_fields)

    let help_before = []
    call add(help_before, '# Welcome to RBQL: SQL with Python expressions.')
    call add(help_before, '# To use RBQL with JavaScript expressions see instructions at the bottom.')
    call add(help_before, '')
    call add(help_before, '# "a1", "a2", etc are column names.')
    call add(help_before, '# You can use them in Python expressions, e.g. "int(a1) * 20 + len(a2) * random.randint(1, 10)"')
    call add(help_before, '# To run the query press F5.')
    call add(help_before, '# For more info visit https://github.com/mechatroner/rainbow_csv')
    call add(help_before, '')
    call add(help_before, '')
    call add(help_before, '# modify:')
    call add(help_before, select_line)
    call setline(1, help_before)
    let help_after = []
    call add(help_after, '')
    call add(help_after, '# To join with another table, modify this:')
    call add(help_after, '#join /path/to/another/table.tsv on a2 == b1')
    call add(help_after, '')
    call add(help_after, '# To filter result set, modify this:')
    call add(help_after, '#where len(a1) > 10')
    call add(help_after, '')
    call add(help_after, '# To sort result set, modify this:')
    call add(help_after, '#order by a2 desc')
    call add(help_after, '')
    call add(help_after, '')
    call add(help_after, '')
    call add(help_after, '# Examples of RBQL queries:')
    call add(help_after, '# select * where a1 == "SELL"')
    call add(help_after, '# select * where a3 in ["car", "plane", "boat"] and int(a1) >= 100')
    call add(help_after, '# select a4, a1')
    call add(help_after, '# select * order by int(a2) desc')
    call add(help_after, '# select * order by random.random()')
    call add(help_after, '# select NR, * where NR <= 100')
    call add(help_after, '# select * where re.match(".*ab.*", a1) is not None')
    call add(help_after, '# select distinct a1, *, 200, int(a2) + 5, "hello world" where NR > 100 and int(a5) < -7 order by a3 ASC')
    call add(help_after, '')
    call add(help_after, '# Next time you can run another query by entering it into vim command line starting with ":Select" command.')
    call add(help_after, '')
    call add(help_after, '')
    call add(help_after, '')
    call add(help_after, '# =======================================================================================')
    call add(help_after, '# Instructions for JavaScript:')
    call add(help_after, '# 1. Ensure you have Node.js installed')
    call add(help_after, '# 2. Add "let g:rbql_meta_language = ''js''" to your .vimrc')
    call add(help_after, '# 3. Execute ":let g:rbql_meta_language = ''js''"')
    call add(help_after, '# 4. Exit this buffer and run F5 again')
    call setline(1 + len(help_before), help_after)
    call cursor(len(help_before), 1)
    w
endfunc


func! rainbow_csv#select_mode()
    if !s:is_rainbow_table()
        echomsg "Error: rainbow_csv is disabled for this buffer"
        return
    endif

    if !s:EnsurePythonInitialization()
        echoerr "Python not found. Unable to run in this mode."
        return
    endif

    if exists("b:selected_buf") && buflisted(b:selected_buf)
        execute "bd " . b:selected_buf
    endif

    let delim = b:rainbow_csv_delim
    let buf_number = bufnr("%")
    let buf_path = expand("%")

    let rb_script_path = s:get_rb_script_path_for_this_table()

    let lines = getline(1, 10)
    if !len(lines)
        echoerr "Error: no lines in file"
        return
    endif

    let fields = s:preserving_smart_split(lines[0], delim)
    let num_fields = len(fields)

    set splitbelow
    execute "split " . rb_script_path
    setlocal noswapfile
    if bufnr("%") == buf_number
        echoerr "Something went wrong"
        return
    endif

    nnoremap <buffer> <F5> :RbRun<cr>
    let b:table_path = buf_path
    let b:table_buf_number = buf_number
    let b:rainbow_select = 1
    "let b:table_csv_delim = delim
    call s:generate_microlang_syntax(num_fields)
    if s:get_meta_language() == "python"
        call s:make_python_demo(num_fields)
    else
        call s:make_javascript_demo(num_fields)
    endif
    call s:create_recurrent_tip("Press F5 to run the query")
endfunc


func! rainbow_csv#copy_file_content_to_buf(src_file_path, dst_buf_no)
    bd!
    redraw!
    echo "executing..."
    execute "buffer " . a:dst_buf_no
    call rainbow_csv#clear_current_buf_content()
    let lines = readfile(a:src_file_path)
    call setline(1, lines)
endfunc


func! s:ShowImportantMessage(msg_header, msg_lines)
    echohl ErrorMsg
    echo a:msg_header
    echohl None
    for msg in a:msg_lines
        echo msg
    endfor
    call input("Press ENTER to continue...")
endfunc


func! rainbow_csv#parse_report(report_content)
    let lines = split(a:report_content, "\n")
    let psv_warning_report = ''
    let psv_error_report = ''
    let psv_query_status = (len(lines) > 0 && len(lines[0]) > 0) ? lines[0] : 'Unknown error'
    let psv_dst_table_path = len(lines) > 1 ? lines[1] : ''
    let report = join(lines[2:], "\n")
    if psv_query_status == "OK"
        let psv_warning_report = report
    else
        let psv_error_report = report
    endif
    return [psv_query_status, psv_error_report, psv_warning_report, psv_dst_table_path]
endfunc


func! s:run_select(table_buf_number, rb_script_path)
    if !s:EnsurePythonInitialization()
        echoerr "Python not found. Unable to run in this mode."
        return
    endif

    let root_delim = getbufvar(a:table_buf_number, "rainbow_csv_delim")
    let meta_language = s:get_meta_language()

    let table_path = expand("#" . a:table_buf_number . ":p")
    if table_path == ""
        "For unnamed buffers. E.g. can happen for stdin-read buffer: `cat data.tsv | vim -`
        let tmp_file_name = "tmp_table_" .  strftime("%Y_%m_%d_%H_%M_%S") . ".txt"
        let table_path = s:rainbowStorage . "/" . tmp_file_name
        "TODO highlighting disappears in parrent buffer after this command, fix it.
        execute "w " . table_path
    endif

    let psv_query_status = 'Unknown error'
    let psv_error_report = 'Something went wrong'
    let psv_warning_report = ''
    let psv_dst_table_path = ''

    redraw!
    echo "executing..."
    let table_path_esc = s:py_source_escape(table_path)
    let rb_script_path_esc = s:py_source_escape(a:rb_script_path)
    let root_delim_esc = s:py_source_escape(root_delim)
    let py_call = 'vim_rbql.run_execute("' . meta_language . '", "' . table_path_esc . '", "' . rb_script_path_esc . '", "' . root_delim_esc . '")'
    if s:system_python_interpreter != ""
        let rbql_executable_path = fnamemodify(s:script_folder_path . '/../python/vim_rbql.py', ":p")
        let cmd_args = [s:system_python_interpreter, shellescape(rbql_executable_path), meta_language, shellescape(table_path), shellescape(a:rb_script_path), shellescape(root_delim)]
        let cmd = join(cmd_args, ' ')
        let report_content = system(cmd)
        let [psv_query_status, psv_error_report, psv_warning_report, psv_dst_table_path] = rainbow_csv#parse_report(report_content)
    elseif has("python3")
        exe 'python3 ' . py_call
    elseif has("python")
        exe 'python ' . py_call
    else
        call s:ShowImportantMessage("Error", ["Python not found, vim must have 'python' or 'python3' feature installed to run in this mode"])
        return
    endif

    if psv_query_status != "OK"
        call s:ShowImportantMessage(psv_query_status, [psv_error_report])
        return
    endif

    execute "e " . psv_dst_table_path
    let b:self_path = psv_dst_table_path
    setlocal noswapfile
    set ft=ignored
    let b:root_table_buf_number = a:table_buf_number
    let b:self_buf_number = bufnr("%")
    call setbufvar(a:table_buf_number, 'selected_buf', b:self_buf_number)

    call rainbow_csv#enable_rainbow("\t")

    nnoremap <buffer> <F4> :bd!<cr>
    nnoremap <buffer> <F6> :call rainbow_csv#create_save_dialog(b:self_buf_number, b:self_path)<cr>
    nnoremap <buffer> <F7> :call rainbow_csv#copy_file_content_to_buf(b:self_path, b:root_table_buf_number)<cr>
    setlocal nomodifiable

    if len(psv_warning_report)
        let warnings = split(psv_warning_report, "\n")
        for wnum in range(len(warnings))
            let warnings[wnum] = 'Warning: ' . warnings[wnum]
        endfor
        call s:ShowImportantMessage("Finished with WARNINGS!", warnings)
    endif

    let table_name = fnamemodify(table_path, ":t")
    call s:create_recurrent_tip("F4: Close; F5: Recursive query; F6: Save...; F7: Copy to " . table_name)
endfunc


func! rainbow_csv#run_cmd_query(...)
    let fargs = a:000
    let query = 'select ' . join(fargs, ' ')
    if !s:is_rainbow_table()
        echomsg "Error: rainbow_csv is disabled for this buffer"
        return
    endif
    call rainbow_csv#restore_statusline()
    let rb_script_path = s:get_rb_script_path_for_this_table()
    call writefile([query], rb_script_path)
    let table_buf_number = bufnr("%")
    call s:run_select(table_buf_number, rb_script_path)
endfunction


func! rainbow_csv#select_from_file()
    if !exists("b:rainbow_select")
        echoerr "Execute from rainbow query buffer"
        return
    endif
    w
    let rb_script_path = expand("%")
    let query_buf_nr = bufnr("%")
    let table_buf_number = b:table_buf_number
    call s:run_select(table_buf_number, rb_script_path)
    execute "bd! " . query_buf_nr
endfunc



func! s:read_settings()
    let lines = []
    if (filereadable(s:rainbowSettingsPath))
        let lines = readfile(s:rainbowSettingsPath)
    endif
    return lines
endfunc


func! s:write_settings(lines)
    call writefile(a:lines, s:rainbowSettingsPath)
endfunc


func! s:try_load_from_settings()
    let fname = expand("%:p")
    let lines = s:read_settings()
    for line in lines
        let fields = split(line, "\t")
        if fields[0] == fname
            let delim = fields[1]
            if delim == 'TAB'
                let delim = "\t"
            endif
            return delim
        endif
    endfor
    return ''
endfunc


func! rainbow_csv#run_autodetection()
    if exists("b:rainbow_csv_delim")
        unlet b:rainbow_csv_delim
    endif
    let delim = s:try_load_from_settings() 
    if delim == 'DISABLED'
        return
    endif
    if (!len(delim))
        let delim = s:auto_detect_delimiter(s:delimiters)
    endif
    if (!len(delim))
        return
    endif
    call rainbow_csv#enable_rainbow(delim)
endfunc


func! s:generate_status_highlighting()
    for groupid in range(len(s:pairs))
        let statusline_hl_group = 'status_color' . groupid
        let cmd = 'highlight %s ctermfg=%s guifg=%s ctermbg=black guibg=black'
        exe printf(cmd, statusline_hl_group, s:pairs[groupid][0], s:pairs[groupid][1])
    endfor
endfunc


func! rainbow_csv#generate_rainbow_syntax(delim)
    let regex_delim = escape(a:delim, s:magic_chars)
    let char_class_delim = s:char_class_escape(a:delim)
    for groupid in range(len(s:pairs))
        let match = 'column' . groupid
        let nextgroup = groupid + 1 < len(s:pairs) ? groupid + 1 : 0
        let cmd = 'syntax match %s /%s[^%s]*/ nextgroup=column%d'
        exe printf(cmd, match, regex_delim, char_class_delim, nextgroup)
        let cmd = 'highlight %s ctermfg=%s guifg=%s'
        exe printf(cmd, match, s:pairs[groupid][0], s:pairs[groupid][1])
    endfor
    let cmd = 'syntax match startcolumn /^[^%s]*/ nextgroup=column1'
    exe printf(cmd, char_class_delim)
    let cmd = 'highlight startcolumn ctermfg=%s guifg=%s'
    exe printf(cmd, s:pairs[0][0], s:pairs[0][1])
endfunc


func! rainbow_csv#generate_escaped_rainbow_syntax(delim)
    let regex_delim = escape(a:delim, s:magic_chars)
    let char_class_delim = s:char_class_escape(a:delim)
    for groupid in range(len(s:pairs))
        let match = 'column' . groupid
        let nextgroup = groupid + 1 < len(s:pairs) ? groupid + 1 : 0
        let cmd = 'syntax match %s /%s[^%s]*/ nextgroup=escaped_column%d,column%d'
        exe printf(cmd, match, regex_delim, char_class_delim, nextgroup, nextgroup)
        let cmd = 'highlight %s ctermfg=%s guifg=%s'
        exe printf(cmd, match, s:pairs[groupid][0], s:pairs[groupid][1])

        let match = 'escaped_column' . groupid
        let nextgroup = groupid + 1 < len(s:pairs) ? groupid + 1 : 0
        let cmd = 'syntax match %s /%s"\([^"]*""\)*[^"]*"$/'
        exe printf(cmd, match, regex_delim)
        let cmd = 'syntax match %s /%s"\([^"]*""\)*[^"]*"%s/me=e-1 nextgroup=escaped_column%d,column%d'
        exe printf(cmd, match, regex_delim, regex_delim, nextgroup, nextgroup)

        let cmd = 'highlight %s ctermfg=%s guifg=%s'
        exe printf(cmd, match, s:pairs[groupid][0], s:pairs[groupid][1])
    endfor
    let cmd = 'syntax match startcolumn /^[^%s]*/ nextgroup=escaped_column1,column1'
    exe printf(cmd, char_class_delim)
    let cmd = 'highlight startcolumn ctermfg=%s guifg=%s'
    exe printf(cmd, s:pairs[0][0], s:pairs[0][1])

    let cmd = 'syntax match startcolumn_escaped /^"\([^"]*""\)*[^"]*"$/'
    exe cmd
    let cmd = 'syntax match startcolumn_escaped /^"\([^"]*""\)*[^"]*"%s/me=e-1 nextgroup=escaped_column1,column1'
    exe printf(cmd, regex_delim)
    let cmd = 'highlight startcolumn_escaped ctermfg=%s guifg=%s'
    exe printf(cmd, s:pairs[0][0], s:pairs[0][1])
endfunc

func! rainbow_csv#regenerate_syntax(delim)
    syntax clear
    if a:delim == ','
        call rainbow_csv#generate_escaped_rainbow_syntax(a:delim)
    else
        call rainbow_csv#generate_rainbow_syntax(a:delim)
    endif
endfunc


func! rainbow_csv#enable_rainbow(delim)
    if (len(s:pairs) < 2 || s:is_rainbow_table())
        return
    endif

    set laststatus=2
    set nocompatible

    nnoremap <buffer> <F5> :RbSelect<cr>
    nnoremap <buffer> <Leader>d :RbGetColumn<cr>

    call rainbow_csv#regenerate_syntax(a:delim)
    call s:generate_status_highlighting()
    highlight status_line_default_hl ctermbg=black guibg=black

    cnoreabbrev <expr> <buffer> Select rainbow_csv#set_statusline_columns() == "dummy" ? 'Select' : 'Select'
    cnoreabbrev <expr> <buffer> select rainbow_csv#set_statusline_columns() == "dummy" ? 'Select' : 'Select'
    cnoreabbrev <expr> <buffer> SELECT rainbow_csv#set_statusline_columns() == "dummy" ? 'Select' : 'Select'

    let b:rainbow_csv_delim = a:delim

    if s:EnsurePythonInitialization()
        call s:create_recurrent_tip("Press F5 to enter \"select\" query mode")
    endif
endfunc


func! s:make_entry(delim)
    let fname = expand("%:p")
    let delim = a:delim
    if delim == "\t"
        let delim = 'TAB'
    endif
    let entry = fname . "\t" . delim
    return entry
endfunc


func! s:save_file_delim(delim)
    let entry = s:make_entry(a:delim)
    let lines = s:read_settings()
    let lines = [entry] + lines
    let lines = lines[:50]
    call s:write_settings(lines)
endfunc


func! s:disable_rainbow()
    if !s:is_rainbow_table()
        return
    endif
    syntax clear startcolumn
    for groupid in range(len(s:pairs))
        let match = 'column' . groupid
        exe "syntax clear " . match
    endfor
    augroup RainbowHintGrp
        autocmd! CursorHold <buffer>
    augroup END
    unmap <buffer> <F5>
    unmap <buffer> <Leader>d
    if exists("b:rainbow_csv_delim")
        unlet b:rainbow_csv_delim
    endif
endfunc


func! rainbow_csv#manual_load()
    let delim = getline('.')[col('.') - 1]  
    call s:disable_rainbow()
    call rainbow_csv#enable_rainbow(delim)
    call s:save_file_delim(delim)
endfunc


func! rainbow_csv#set_header_manually(fname)
    if !s:is_rainbow_table()
        echomsg "Error: rainbow_csv is disabled for this buffer"
        return
    endif
    let delim = b:rainbow_csv_delim
    let entry = s:make_entry(delim)
    let entry = entry . "\t" . a:fname
    let lines = s:read_settings()
    let lines = [entry] + lines
    let lines = lines[:50]
    call s:write_settings(lines)
endfunc


func! s:read_column_name(colNo, numCols)
    let names = s:read_column_names()
    if !len(names)
        return 'n/a (header not found/empty)'
    endif

    if (a:colNo >= len(names))
        return 'n/a (no field in header)'
    endif
    if (a:numCols != len(names))
        return names[a:colNo] . ' (Warning: number of columns in header and csv file mismatch)'
    endif
    return names[a:colNo]
endfunc


func! rainbow_csv#get_column()
    let line = getline('.')
    let kb_pos = col('.')
    if !s:is_rainbow_table()
        echomsg "Error: rainbow_csv is disabled for this buffer"
        return
    endif
    let delim = b:rainbow_csv_delim

    let fields = s:preserving_smart_split(line, delim)
    let numCols = len(fields)

    let col_num = 0
    let cpos = len(fields[col_num]) 
    while kb_pos > cpos && col_num + 1 < len(fields)
        let col_num = col_num + 1
        let cpos = cpos + 1 + len(fields[col_num])
    endwhile

    let col_name = s:read_column_name(col_num, numCols)
    echo printf('Col: [%s], Name: [%s]', col_num + 1, col_name)
endfunc


func! rainbow_csv#manual_disable()
    call s:disable_rainbow()
    call s:save_file_delim('DISABLED')
endfunc
