"==============================================================================
"  Description: rainbow csv
"==============================================================================


let s:max_columns = exists('g:rcsv_max_columns') ? g:rcsv_max_columns : 30
let s:rainbowStorage = $HOME . '/.rainbow_csv_storage'
let s:rainbowSettingsPath = $HOME . '/.rainbow_csv_files'

let s:script_folder_path = fnamemodify(resolve(expand('<sfile>:p')), ':h')
let s:python_env_initialized = 0


func! s:is_rainbow_table()
    return exists("b:rainbow_csv_delim") && len(b:rainbow_csv_delim)
endfunc


func! s:create_recurrent_tip(tip_text)
    let b:rb_tip_text = a:tip_text
    augroup RainbowHintGrp
        autocmd! CursorHold <buffer>
        autocmd CursorHold <buffer> echo b:rb_tip_text
    augroup END
    redraw
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


func! s:SelectDirectory()
    let line = getline('.')
    call feedkeys(":RbSaveAndSwap " . line . "/")
endfunction


func! rainbow_csv#create_save_dialog(table_buf_nr, table_path)
    noswapfile enew
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
    redraw
    setlocal nomodifiable
    nnoremap <silent> <buffer> <CR> :call <SID>SelectDirectory()<CR>
endfunction



function! s:EnsurePythonInitialization()
    if (s:python_env_initialized)
        return 1
    endif
    if has("python3")
        py3 import sys
        py3 import vim
        exe 'python3 sys.path.insert(0, "' . s:script_folder_path . '/../python")'
        py3 import rbql
    elseif has("python")
        py import sys
        py import vim
        exe 'python sys.path.insert(0, "' . s:script_folder_path . '/../python")'
        py import rbql
    else
        echoerr "vim must have 'python' or 'python3' feature installed to run in this mode"
        return 0
    endif
    let s:python_env_initialized = 1
    return 1
endfunction

func! s:ensure_storage_exists()
    if !isdirectory(s:rainbowStorage)
        call mkdir(s:rainbowStorage, "p")
    endif
endfunc


func! s:lines_are_delimited(lines, delim)
    let num_fields = len(split(a:lines[0], a:delim))
    if (num_fields < 2 || num_fields > s:max_columns)
        return 0
    endif
    for line in a:lines
        let nfields = len(split(line, a:delim)) 
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


let s:pairs = [
    \ ['darkred',     'darkred'],
    \ ['darkblue',    'darkblue'],
    \ ['darkgreen',   'darkgreen'],
    \ ['darkmagenta', 'darkmagenta'],
    \ ['darkcyan',    'darkcyan'],
    \ ['red',         'red'],
    \ ['blue',        'blue'],
    \ ['green',       'green'],
    \ ['magenta',     'magenta'],
    \ ['NONE',        'NONE'],
    \ ]

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



func! s:do_run_select(table_path, rb_script_path, py_script_path, dst_table_path, delim)
    let query_status = 'Unknown error'
    let report = 'Something went wrong'
    let py_call = 'rbql.vim_execute("' . a:table_path. '", "' . a:rb_script_path . '", "' . a:py_script_path . '", "' . a:dst_table_path . '", "' . a:delim . '")'
    if has("python3")
        exe 'python3 ' . py_call
    elseif has("python")
        exe 'python ' . py_call
    else
        return ["python not found", "vim must have 'python' or 'python3' feature installed to run in this mode"]
    endif
    return [query_status, report]
endfunc


func! rainbow_csv#clear_current_buf_content()
    let nl = line("$")
    call cursor(1, 1)
    execute "delete " . nl
endfunc


func! rainbow_csv#select_mode()
    if !s:is_rainbow_table()
        echomsg "Error: rainbow_csv is disabled for this buffer"
        return
    endif

    if exists("b:selected_buf") && buflisted(b:selected_buf)
        execute "bd " . b:selected_buf
    endif

    if !s:EnsurePythonInitialization()
        return
    endif

    let delim = b:rainbow_csv_delim
    let buf_number = bufnr("%")
    let buf_path = expand("%")

    let rb_script_name = expand("%:t") . ".rb"
    call s:ensure_storage_exists()
    let rb_script_path = s:rainbowStorage . '/' . rb_script_name

    let already_exists = filereadable(rb_script_path)

    let lines = getline(1, 10)
    if !len(lines)
        echoerr "Error: no lines in file"
        return
    endif
    let num_fields = len(split(lines[0], delim))
    let new_rows = []
    for nf in range(1, num_fields)
        call add(new_rows, 'a' . nf . ',')
    endfor

    execute "noswapfile e " . rb_script_path

    nnoremap <buffer> <F5> :RbRun<cr>
    call rainbow_csv#generate_microlang_syntax(num_fields)
    let b:table_path = buf_path
    let b:table_buf_number = buf_number
    let b:rainbow_select = 1
    let b:table_csv_delim = delim

    call rainbow_csv#clear_current_buf_content()
    let help_before = []
    call add(help_before, '# Welcome to RBQL: SQL with python expressions')
    call add(help_before, "")
    call add(help_before, '# "a1", "a2", etc are column names')
    call add(help_before, '# You can use them in python expression, e.g. "int(a1) * 20 + len(a2) * random.randint(1, 10)"')
    call add(help_before, '# To run the query press F5')
    call add(help_before, '# For more info visit https://github.com/mechatroner/rainbow_csv')
    call add(help_before, '')
    call add(help_before, 'select')
    call setline(1, help_before)
    for nf in range(num_fields)
        call setline(nf + 1 + len(help_before), new_rows[nf])
    endfor
    let help_after = []
    call add(help_after, '')
    call add(help_after, '')
    call add(help_after, '# To join with another table, modify this:')
    call add(help_after, '#left join /path/to/another/table.tsv on a2 == b1')
    call add(help_after, '')
    call add(help_after, '# To filter result set, modify this:')
    call add(help_after, '#where len(a1) > 10')
    call add(help_after, '')
    call add(help_after, '# To sort result set, modify this:')
    call add(help_after, '#order by a2 desc')
    call add(help_after, '')
    call add(help_after, '# Examples of rbql queries:')
    call add(help_after, '# select * where a1 == "SELL"')
    call add(help_after, '# select * where a3 in ["car", "plane", "boat"] and int(a1) >= 100')
    call add(help_after, '# select * where lnum <= 10 # this is an equivalent of bash command "head -n 10", lnum is 1-based')
    call add(help_after, '# select a1, a4 # this is an equivalent of bash command "cut -f 1,4"')
    call add(help_after, '# select * order by int(a2) desc # this is an equivalent of bash command "sort -k2,2 -r -n"')
    call add(help_after, '# select * order by random.random() # random sort, this is an equivalent of bash command "sort -R"')
    call add(help_after, '# select lnum, * # - enumerate lines, lnum is 1-based')
    call add(help_after, '# select * where re.match(".*ab.*", a1) is not None # select entries where first column has "ab" pattern')
    call add(help_after, '# select * where flike(a1, "%ab%") # same as previous, but using "flike()" function (equivalent of SQL "LIKE" operator)')
    call add(help_after, '# select distinct a1, *, 200, int(a2) + 5, "hello world" where lnum > 100 and int(a5) < -7 order by a3 ASC')
    call add(help_after, '')
    call add(help_after, '')
    call add(help_after, '# Did you know? You have rbql.py script in the .vim extension folder which you can run from command line like this:')
    call add(help_after, '# ./rbql.py --query "select a1, a2 order by a1" < input.tsv')
    call add(help_after, '# run ./rbql.py -h for more info')
    call setline(num_fields + 1 + len(help_before), help_after)
    call cursor(1 + len(help_before), 1)
    w
    call s:create_recurrent_tip("Press F5 to run the query")
endfunc


func! rainbow_csv#copy_file_content_to_buf(src_file_path, dst_buf_no)
    bd!
    redraw
    echo "executing..."
    execute "buffer " . a:dst_buf_no
    call rainbow_csv#clear_current_buf_content()
    let lines = readfile(a:src_file_path)
    call setline(1, lines)
endfunc



func! rainbow_csv#run_select()
    if !exists("b:rainbow_select")
        echoerr "Execute from rainbow query buffer"
        return
    endif

    w
    let rb_script_path = expand("%")

    if !s:EnsurePythonInitialization()
        return
    endif

    let py_module_name = "vim_rb_convert_" .  strftime("%Y_%m_%d_%H_%M_%S") . ".py"

    let cache_dir = expand("%:p:h")
    let py_script_path = cache_dir . "/" . py_module_name
    let table_name = fnamemodify(b:table_path, ":t")
    let table_buf_number = b:table_buf_number
    let dst_table_path = cache_dir . "/" . table_name . ".rbselected"

    redraw
    echo "executing..."

    let [query_status, report] = s:do_run_select(b:table_path, rb_script_path, py_script_path, dst_table_path, b:table_csv_delim)
    if query_status == "Parsing Error"
        echohl ErrorMsg
        echo "Parsing Error"
        echohl None
        echo report
        return
    endif
    if query_status == "Execution Error"
        echohl ErrorMsg
        echo "Execution Error"
        echohl None
        echo report
        echo "Generated python module was saved here: " . py_script_path
        return
    endif
    if query_status != "OK"
        echohl ErrorMsg
        echo "Unknown Error has occured during execution of select query"
        echohl None
        return
    endif
    bd!
    execute "noswapfile e " . dst_table_path
    let b:self_path = dst_table_path
    let b:root_table_buf_number = table_buf_number
    let b:self_buf_number = bufnr("%")
    call setbufvar(table_buf_number, 'selected_buf', b:self_buf_number)
    nnoremap <buffer> <silent> <F4> :bd!<cr>
    nnoremap <buffer> <silent> <F5> :call rainbow_csv#copy_file_content_to_buf(b:self_path, b:root_table_buf_number)<cr>
    nnoremap <buffer> <silent> <F6> :call rainbow_csv#create_save_dialog(b:self_buf_number, b:self_path)<cr>
    setlocal nomodifiable
    call s:create_recurrent_tip("Press F4 to close, F5 to replace " . table_name . " with this table or F6 to save as a new file" )
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
    let b:rainbow_csv_delim = ''
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
    call rainbow_csv#generate_syntax(delim)
endfunc


func! rainbow_csv#generate_microlang_syntax(nlines)
    let npairs = len(s:pairs)
    if (npairs < 2)
        return
    endif

    set ft=python

    for pn in range(npairs)
        let cmd = 'highlight rbql_color%d ctermfg=%s guifg=%s'
        exe printf(cmd, pn + 1, s:pairs[pn][0], s:pairs[pn][1])
    endfor

    for lnum in range(1, a:nlines)
        let color_num = ((lnum - 1) % npairs) + 1
        let cmd = 'syntax keyword rbql_color%d a%d'
        exe printf(cmd, color_num, lnum)
    endfor

    highlight RbCmd ctermbg=blue guibg=blue
    syntax keyword RbCmd SELECT WHERE INITIALIZE DESC ASC
    syntax keyword RbCmd select where initialize desc asc
    syntax match RbCmd "ORDER BY"
    syntax match RbCmd "order by"
    syntax match RbCmd "INNER JOIN"
    syntax match RbCmd "inner join"
    syntax match RbCmd "LEFT JOIN"
    syntax match RbCmd "left join"
    syntax match RbCmd "LEFT JOIN STRICT"
    syntax match RbCmd "left join strict"
endfunc

func! rainbow_csv#generate_syntax(delim)
    if (len(s:pairs) < 2)
        return
    endif

    if s:is_rainbow_table()
        return
    endif

    nnoremap <buffer> <silent> <F5> :RbSelect<cr>
    nnoremap <buffer> <silent> <Leader>d :RbGetColumn<cr>

    for groupid in range(len(s:pairs))
        let match = 'column' . groupid
        let nextgroup = groupid + 1 < len(s:pairs) ? groupid + 1 : 0
        let cmd = 'syntax match %s /%s[^%s]*/ nextgroup=column%d'
        exe printf(cmd, match, a:delim, a:delim, nextgroup)
        let cmd = 'highlight %s ctermfg=%s guifg=%s'
        exe printf(cmd, match, s:pairs[groupid][0], s:pairs[groupid][1])
    endfor

    let cmd = 'syntax match startcolumn /^[^%s]*/ nextgroup=column1'
    exe printf(cmd, a:delim)
    let cmd = 'highlight startcolumn ctermfg=%s guifg=%s'
    exe printf(cmd, s:pairs[0][0], s:pairs[0][1])
    let b:rainbow_csv_delim = a:delim
    call s:create_recurrent_tip("Press F5 to enter \"select\" query mode")
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


func! s:disable_syntax()
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
    let b:rainbow_csv_delim = ''
endfunc


func! rainbow_csv#manual_load()
    let delim = getline('.')[col('.') - 1]  
    call s:disable_syntax()
    call rainbow_csv#generate_syntax(delim)
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
    let pos = col('.') - 1
    if !s:is_rainbow_table()
        echomsg "Error: rainbow_csv is disabled for this buffer"
        return
    endif
    let delim = b:rainbow_csv_delim

    let colNo = len(split(line[0:pos], delim))
    let numCols = len(split(line, delim))

    let colName = s:read_column_name(colNo - 1, numCols)
    echo 'Col: [' . colNo . '], Name: [' . colName . ']'
endfunc


func! rainbow_csv#manual_disable()
    call s:disable_syntax()
    call s:save_file_delim('DISABLED')
endfunc
