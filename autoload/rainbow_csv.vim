"==============================================================================
"
" Description: Rainbow CSV
" Authors: Dmitry Ignatovich, ...
"
"==============================================================================

let s:max_columns = exists('g:rcsv_max_columns') ? g:rcsv_max_columns : 30
let s:rb_storage_dir = exists('g:rb_storage_dir') ? g:rb_storage_dir : $HOME . '/.rainbow_csv_storage'
let s:table_names_settings = exists('g:table_names_settings') ? g:table_names_settings : $HOME . '/.rbql_table_names'
let s:rainbow_table_index = exists('g:rainbow_table_index') ? g:rainbow_table_index : $HOME . '/.rbql_table_index'

let s:script_folder_path = expand('<sfile>:p:h:h')
let s:python_env_initialized = 0
let s:js_env_initialized = 0
let s:system_python_interpreter = ''

let s:magic_chars = '^*$.~/[]\'

let s:named_syntax_map = {'csv': [',', 'quoted', ''], 'csv_semicolon': [';', 'quoted', ''], 'tsv': ["\t", 'simple', ''], 'csv_pipe': ['|', 'simple', ''], 'csv_whitespace': [" ", 'whitespace', ''], 'rfc_csv': [',', 'quoted_rfc', ''], 'rfc_semicolon': [';', 'quoted_rfc', '']}

let s:autodetection_delims = exists('g:rcsv_delimiters') ? g:rcsv_delimiters : ["\t", ",", ";", "|"]

let s:number_regex = '^[0-9]\+\(\.[0-9]\+\)\?$'
let s:non_numeric = -1

let s:align_progress_bar_position = 0
let s:progress_bar_size = 20

" Vim has 2 different variables: filetype and syntax. syntax is a subset of filetype
" We need to use both of them.


" XXX Use :syntax command to list all current syntax groups
" XXX Use :highlight command to list all current highlight groups


" TODO fix update -> Update switch it also occures with this `:echo "update "` -> `:echo "Update "` scenario. but only with csv files!
" It might be possible  to modify set_statusline_columns() to read current
" command line text and if it starts with "select" indeed, then replace
" (return special flag) otherwise do not replace by ternary expression

" TODO implement select -> Select switch for monocolumn files
"
" TODO support comment prefixes

" TODO implement csv_lint for "rfc_csv" dialect


func! s:get_auto_policy_for_delim(delim)
    if a:delim == ',' || a:delim == ';'
        return 'quoted'
    elseif a:delim == ' '
        return 'whitespace'
    else
        return 'simple'
    endif
endfunc


func! s:init_groups_from_links()
    let link_groups = ['String', 'Comment', 'NONE', 'Special', 'Identifier', 'Type', 'Question', 'CursorLineNr', 'ModeMsg', 'Title']
    if s:has_custom_links()
        let link_groups = g:rcsv_colorlinks
    endif
    for gi in range(len(link_groups))
        let cmd = 'highlight link status_color%d %s'
        exe printf(cmd, gi, link_groups[gi])
        let cmd = 'highlight link rbql_color%d %s'
        exe printf(cmd, gi, link_groups[gi])
        let cmd = 'highlight link column%d %s'
        exe printf(cmd, gi, link_groups[gi])
        let cmd = 'highlight link escaped_column%d %s'
        exe printf(cmd, gi, link_groups[gi])
    endfor
    let s:num_groups = len(link_groups)
endfunc


func! s:has_custom_colors()
    return exists('g:rcsv_colorpairs') && len(g:rcsv_colorpairs) > 1
endfunc


func! s:has_custom_links()
    return exists('g:rcsv_colorlinks') && len(g:rcsv_colorlinks) > 1
endfunc


func! s:use_system_python()
    return exists('g:rbql_use_system_python') ? g:rbql_use_system_python : 0
endfunc


func! s:get_rbql_with_headers()
    return exists('g:rbql_with_headers') ? g:rbql_with_headers : 0
endfunc


func! s:init_groups_from_colors()
    let pairs = [['red', 'red'], ['green', 'green'], ['blue', 'blue'], ['magenta', 'magenta'], ['NONE', 'NONE'], ['darkred', 'darkred'], ['darkblue', 'darkblue'], ['darkgreen', 'darkgreen'], ['darkmagenta', 'darkmagenta'], ['darkcyan', 'darkcyan']]
    if s:has_custom_colors()
        let pairs = g:rcsv_colorpairs
    endif
    for gi in range(len(pairs))
        let cmd = 'highlight status_color%d ctermfg=%s guifg=%s ctermbg=black guibg=black'
        exe printf(cmd, gi, pairs[gi][0], pairs[gi][1])
        let cmd = 'highlight rbql_color%d ctermfg=%s guifg=%s'
        exe printf(cmd, gi, pairs[gi][0], pairs[gi][1])
        let cmd = 'highlight column%d ctermfg=%s guifg=%s'
        exe printf(cmd, gi, pairs[gi][0], pairs[gi][1])
        let cmd = 'highlight escaped_column%d ctermfg=%s guifg=%s'
        exe printf(cmd, gi, pairs[gi][0], pairs[gi][1])
    endfor
    let s:num_groups = len(pairs)
endfunc


func! rainbow_csv#init_rb_color_groups()
    if !exists("g:syntax_on") || s:has_custom_colors()
        call s:init_groups_from_colors()
    else
        call s:init_groups_from_links()
    endif
    highlight link escaped_startcolumn column0

    highlight RbCmd ctermbg=blue guibg=blue
endfunc



augroup RainbowCsvPluginInitAuGrp
    " We need this autocmd only for users who has g:rcsv_colorpairs customization enabled and who set custom colorscheme manually or in .vimrc.
    autocmd!
    " If someone sets syntax on VimEnter autocmd, it will overwrite the color groups, so we restore them back here
    autocmd VimEnter * call rainbow_csv#init_rb_color_groups()
    autocmd ColorScheme * call rainbow_csv#init_rb_color_groups()
augroup END


func! s:try_read_lines(src_path)
    let lines = []
    if (filereadable(a:src_path))
        let lines = readfile(a:src_path)
    endif
    return lines
endfunc


func! s:try_read_index(src_path)
    let lines = s:try_read_lines(a:src_path)
    let records = []
    for line in lines
        let fields = split(line, "\t", 1)
        call add(records, fields)
    endfor
    return records
endfunc


func! s:write_index(records, dst_path)
    let lines = []
    for record in a:records
        let new_line = join(record, "\t")
        call add(lines, new_line)
    endfor
    call writefile(lines, a:dst_path)
endfunc


func! s:update_records(records, key, new_record)
    let old_idx = -1
    for ir in range(len(a:records))
        let record = a:records[ir]
        if len(record) && record[0] == a:key
            let old_idx = ir
        endif
    endfor
    if old_idx != -1
        call remove(a:records, old_idx)
    endif
    call add(a:records, a:new_record)
    return a:records
endfunc


func! s:index_encode_delim(delim)
    " We need this ugly function to keep backward-compatibility with old single-char delim format
    if a:delim == "\t"
        return 'TAB'
    endif
    if len(a:delim) > 1
        let result = substitute(a:delim, '\\', '\\\\', "g")
        let result = substitute(result, '\t', '\\t', "g")
        return 'multichar:' . result
    endif
    return a:delim
endfunc


func! s:index_decode_delim(encoded_delim)
    if a:encoded_delim == "TAB"
        return "\t"
    endif
    if stridx(a:encoded_delim, 'multichar:') == 0
        let result = strpart(a:encoded_delim, len('multichar:'))
        let result = substitute(result, '\\t', '\t', 'g')
        let result = substitute(result, '\\\\', '\\', 'g')
        return result
    endif
    return a:encoded_delim
endfunc


func! s:update_table_record(table_path, delim, policy, comment_prefix)
    if !len(a:table_path)
        " For tmp buffers e.g. `cat table.csv | vim -`
        return
    endif
    if stridx(a:comment_prefix, "\t") != -1
        return " Failsafe to preserve index structure. No one will use comment prefix with tab anyway
    endif
    let encoded_delim = s:index_encode_delim(a:delim)
    let new_record = [a:table_path, encoded_delim, a:policy, a:comment_prefix]
    let records = s:try_read_index(s:rainbow_table_index)
    let records = s:update_records(records, a:table_path, new_record)
    if len(records) > 100
        call remove(records, 0)
    endif
    call s:write_index(records, s:rainbow_table_index)
endfunc


func! s:get_auto_comment_prefix()
    return exists('g:rainbow_comment_prefix') ? g:rainbow_comment_prefix : ''
endfunc


func! s:get_table_record(table_path)
    if !len(a:table_path)
        return []
    endif
    let records = s:try_read_index(s:rainbow_table_index)
    for record in records
        if len(record) >= 3 && record[0] == a:table_path
            let delim = s:index_decode_delim(record[1])
            let policy = record[2]
            let comment_prefix = len(record) > 3 ? record[3] : s:get_auto_comment_prefix()
            if comment_prefix == '@auto_comment_prefix@'
                let comment_prefix = s:get_auto_comment_prefix()
            endif
            return [delim, policy, comment_prefix]
        endif
    endfor
    return []
endfunc


func! s:string_to_hex(src)
    let result = ''
    for nt in range(len(a:src))
        let result .= printf("%x", char2nr(a:src[nt]))
    endfor
    return result
endfunc


func! s:hex_to_string(src)
    let result = ''
    let nt = 0
    while nt < len(a:src)
        let result .= nr2char(str2nr(strpart(a:src, nt, 2), 16))
        let nt += 2
    endwhile
    return result
endfunc


func! rainbow_csv#dialect_to_ft(delim, policy, comment_prefix)
    for [ft, delim_policy] in items(s:named_syntax_map)
        if a:delim == delim_policy[0] && a:policy == delim_policy[1] && a:comment_prefix == delim_policy[2]
            return ft
        endif
    endfor
    return join(['rcsv', s:string_to_hex(a:delim), a:policy, s:string_to_hex(a:comment_prefix)], '_')
endfunc


func! rainbow_csv#ft_to_dialect(ft_val)
    if has_key(s:named_syntax_map, a:ft_val)
        return s:named_syntax_map[a:ft_val]
    endif
    let ft_parts = split(a:ft_val, '_')
    if len(ft_parts) < 3 || ft_parts[0] != 'rcsv'
        return ['', 'monocolumn', '']
    endif
    let comment_prefix = len(ft_parts) == 4 ? s:hex_to_string(ft_parts[3]) : ''
    return [s:hex_to_string(ft_parts[1]), ft_parts[2], comment_prefix]
endfunc


func! rainbow_csv#ensure_syntax_exists(rainbow_ft, delim, policy, comment_prefix)
    if a:policy == 'quoted'
        let syntax_lines = rainbow_csv#generate_escaped_rainbow_syntax(a:delim)
    elseif a:policy == 'quoted_rfc'
        let syntax_lines = rainbow_csv#generate_escaped_rfc_rainbow_syntax(a:delim)
    elseif a:policy == 'simple'
        let syntax_lines = rainbow_csv#generate_rainbow_syntax(a:delim)
    elseif a:policy == 'whitespace'
        let syntax_lines = rainbow_csv#generate_whitespace_syntax()
    else
        echoerr 'bad delim policy: ' . a:policy
    endif
    if a:comment_prefix != ''
        let regex_comment_prefix = escape(a:comment_prefix, s:magic_chars)
        call add(syntax_lines, 'syntax match Comment /^' . regex_comment_prefix . '.*$/')
    endif
    let syntax_file_path = s:script_folder_path . '/syntax/' . a:rainbow_ft . '.vim'
    call writefile(syntax_lines, syntax_file_path)
endfunc


func! rainbow_csv#generate_named_dialects() " This is an externally-invoked function which is used to pre-generate well-known syntax files
    for [ft, delim_policy] in items(s:named_syntax_map)
        call rainbow_csv#ensure_syntax_exists(ft, delim_policy[0], delim_policy[1], delim_policy[2])
    endfor
endfunc


func! rainbow_csv#get_current_dialect()
    " Using &syntax instead of &ft here because they can have different value i.e. after manual syntax assignment set syntax = ...
    let current_ft = &syntax
    return rainbow_csv#ft_to_dialect(current_ft)
endfunc


func! rainbow_csv#is_rainbow_table()
    return rainbow_csv#get_current_dialect()[1] != 'monocolumn'
endfunc


func! rainbow_csv#is_rainbow_table_or_was_just_disabled()
    return (exists("b:rainbow_features_enabled") && b:rainbow_features_enabled == 1)
endfunc


func! s:get_meta_language()
    let lang_lw = 'python'
    if exists("g:rbql_meta_language")
        let lang_lw = tolower(g:rbql_meta_language)
    endif
    if exists("g:rbql_backend_language")
        let lang_lw = tolower(g:rbql_backend_language)
    endif
    if lang_lw == 'javascript'
        let lang_lw = 'js'
    endif
    return lang_lw
endfunc


func! s:has_python_27()
    if !has("python")
        return 0
    endif
    py import sys
    if pyeval('sys.version_info[1]') < 7
        return 0
    endif
    return 1
endfunc


func! s:read_virtual_header(delim, policy)
    " TODO rename and refactor into try_set_virtual_header() - without parameters, get delim and policy from the current filetype
    let table_path = resolve(expand("%:p"))
    let headerName = table_path . '.header'
    if (!filereadable(headerName))
        return []
    endif
    let lines = readfile(headerName, '', 1)
    if (!len(lines))
        return []
    endif
    let line = lines[0]
    let names = []
    if a:policy == 'monocolumn'
        let names = [line]
    else
        let regex_delim = escape(a:delim, s:magic_chars)
        let names = split(line, regex_delim)
    endif
    return names
endfunc


func! rainbow_csv#dbg_set_system_python_interpreter(interpreter)
    let s:system_python_interpreter = a:interpreter
endfunction


func! rainbow_csv#find_python_interpreter()
    " Checking `python3` first, because `python` could be theorethically linked to python 2.6
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
    " Strings in 'substitute' must follow esoteric rules, see `:help substitute()`
    let dst = substitute(a:src, '\\', '\\\\', "g")
    let dst = substitute(dst, '\t', '\\t', "g")
    let dst = substitute(dst, '"', '\\"', "g")
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


function! s:test_coverage()
    if !exists("g:rbql_dbg_test_coverage")
        return 0
    endif
    return reltime()[1] % 2
endfunc


function! s:EnsureJavaScriptInitialization()
    if (s:js_env_initialized)
        return 1
    endif
    let js_version = tolower(system('node --version'))
    if (v:shell_error != 0)
        return 0
    endif
    let s:js_env_initialized = 1
    return 1
endfunction


function! s:EnsurePythonInitialization()
    if (s:python_env_initialized)
        return 1
    endif
    let py_home_dir = s:script_folder_path . '/rbql_core'
    let py_home_dir = s:py_source_escape(py_home_dir)
    if has("python3") && !s:use_system_python() && !s:test_coverage()
        py3 import sys
        py3 import vim
        exe 'python3 sys.path.insert(0, "' . py_home_dir . '")'
        py3 import vim_rbql
    elseif s:has_python_27() && !s:use_system_python() && !s:test_coverage()
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
    if !isdirectory(s:rb_storage_dir)
        call mkdir(s:rb_storage_dir, "p")
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


function! rainbow_csv#strip_spaces(input_string)
    return substitute(a:input_string, '^ *\(.\{-}\) *$', '\1', '')
endfunction


func! rainbow_csv#unescape_quoted_fields(src)
    let res = a:src
    for nt in range(len(res))
        let res[nt] = rainbow_csv#strip_spaces(res[nt])
        if len(res[nt]) >= 2 && res[nt][0] == '"'
            let res[nt] = strpart(res[nt], 1, len(res[nt]) - 2)
        endif
        let res[nt] = substitute(res[nt], '""', '"', 'g')
    endfor
    return res
endfunc


func! rainbow_csv#preserving_quoted_split(line, delim)
    let src = a:line
    if stridx(src, '"') == -1
        " Optimization for majority of lines
        let regex_delim = escape(a:delim, s:magic_chars)
        return [split(src, regex_delim, 1), 0]
    endif
    let result = []
    let cidx = 0
    let has_warning = 0
    while cidx < len(src)
        let uidx = cidx
        while uidx < len(src) && src[uidx] == ' '
            let uidx += 1
        endwhile
        if src[uidx] == '"'
            let uidx += 1
            while 1
                let uidx = stridx(src, '"', uidx)
                if uidx == -1
                    call add(result, strpart(src, cidx))
                    return [result, 1]
                endif
                let uidx += 1
                if uidx < len(src) && src[uidx] == '"'
                    let uidx += 1
                    continue
                endif
                while uidx < len(src) && src[uidx] == ' '
                    let uidx += 1
                endwhile
                if uidx >= len(src) || src[uidx] == a:delim
                    call add(result, strpart(src, cidx, uidx - cidx))
                    let cidx = uidx + 1
                    break
                endif
                let has_warning = 1
            endwhile
        else
            let uidx = stridx(src, a:delim, uidx)
            if uidx == -1
                let uidx = len(src)
            endif
            let field = strpart(src, cidx, uidx - cidx)
            let cidx = uidx + 1
            call add(result, field)
            let has_warning = has_warning || stridx(field, '"') != -1
        endif
    endwhile
    if src[len(src) - 1] == a:delim
        call add(result, '')
    endif
    return [result, has_warning]
endfunc


func! rainbow_csv#quoted_split(line, delim)
    let quoted_fields = rainbow_csv#preserving_quoted_split(a:line, a:delim)[0]
    let clean_fields = rainbow_csv#unescape_quoted_fields(quoted_fields)
    return clean_fields
endfunc


func! rainbow_csv#whitespace_split(line, preserve_whitespaces)
    let result = []
    let cidx = 0
    while cidx < len(a:line)
        let uidx = cidx
        while uidx < len(a:line) && a:line[uidx] == ' '
            let uidx += 1
        endwhile
        let startidx = uidx
        while uidx < len(a:line) && a:line[uidx] != ' '
            let uidx += 1
        endwhile
        if uidx == startidx
            if a:preserve_whitespaces && len(result)
                let startidx = cidx
                let result[len(result) - 1] = result[len(result) - 1] . strpart(a:line, startidx, uidx - startidx)
            endif
            break
        endif
        if a:preserve_whitespaces
            let startidx = len(result) ? cidx + 1 : cidx
        endif
        let field = strpart(a:line, startidx, uidx - startidx)
        let cidx = uidx
        call add(result, field)
    endwhile
    if len(result) == 0
        if a:preserve_whitespaces
            call add(result, a:line)
        else
            call add(result, '')
        endif
    endif
    return result
endfunc


func! rainbow_csv#smart_split(line, delim, policy)
    let stripped = rainbow_csv#rstrip(a:line)
    if a:policy == 'monocolumn'
        return [stripped]
    elseif a:policy == 'quoted' || a:policy == 'quoted_rfc'
        return rainbow_csv#quoted_split(stripped, a:delim)
    elseif a:policy == 'simple'
        let regex_delim = escape(a:delim, s:magic_chars)
        return split(stripped, regex_delim, 1)
    elseif a:policy == 'whitespace'
        return rainbow_csv#whitespace_split(a:line, 0)
    else
        echoerr 'bad delim policy'
    endif
endfunc


func! rainbow_csv#preserving_smart_split(line, delim, policy)
    let stripped = rainbow_csv#rstrip(a:line)
    if a:policy == 'monocolumn'
        return [[stripped], 0]
    elseif a:policy == 'quoted' || a:policy == 'quoted_rfc'
        return rainbow_csv#preserving_quoted_split(stripped, a:delim)
    elseif a:policy == 'simple'
        let regex_delim = escape(a:delim, s:magic_chars)
        return [split(stripped, regex_delim, 1), 0]
    elseif a:policy == 'whitespace'
        return [rainbow_csv#whitespace_split(a:line, 1), 0]
    else
        echoerr 'bad delim policy'
    endif
endfunc


func! rainbow_csv#csv_lint()
    let [delim, policy, comment_prefix] = rainbow_csv#get_current_dialect()
    if policy == 'monocolumn'
        echoerr "CSVLint is available only for highlighted CSV files"
        return
    endif
    if policy == 'quoted_rfc'
        " TODO implement
        echoerr "CSVLint is not implemented yet for rfc_csv"
        return
    endif
    let lastLineNo = line("$")
    let num_fields = 0
    for linenum in range(1, lastLineNo)
        let line = getline(linenum)
        if comment_prefix != '' && stridx(line, comment_prefix) == 0 " Using stridx is less efficient than using 'startswith', since we try to match at every position, but vimscript doesn't have 'startswith'
            continue
        endif
        let [fields, has_warning] = rainbow_csv#preserving_smart_split(line, delim, policy)
        if has_warning
            echoerr printf("Line %s has formatting error: double quote chars are not consistent", linenum)
            return
        endif
        let num_fields_cur = len(fields)
        if !num_fields
            let num_fields = num_fields_cur
        endif
        if (num_fields != num_fields_cur)
            echoerr printf("Number of fields is not consistent: e.g. line 1 has %s fields, and line %s has %s fields", num_fields, linenum, num_fields_cur)
            return
        endif
    endfor
    echomsg "CSVLint: OK"
endfunc


func! rainbow_csv#update_subcomponent_stats(field, is_first_line, max_field_components_lens)
    " Extract overall field length and length of integer and fractional parts of the field if it represents a number.
    " Here `max_field_components_lens` is a tuple: (max_field_length, max_integer_part_length, max_fractional_part_length)
    let field_length = strdisplaywidth(a:field)
    if field_length > a:max_field_components_lens[0]
        let a:max_field_components_lens[0] = field_length
    endif
    if a:max_field_components_lens[1] == s:non_numeric
        " Column is not a number, early return.
        return
    endif
    let pos = match(a:field, s:number_regex)
    if pos == -1
        if !a:is_first_line && field_length " Checking field_length here allows numeric columns to have some of the fields empty.
            " We only mark the column as non-header if we know that this is not a header line.
            let a:max_field_components_lens[1] = s:non_numeric
            let a:max_field_components_lens[2] = s:non_numeric
        endif
        return
    endif
    let dot_pos = stridx(a:field, '.')
    let cur_integer_part_length = dot_pos == -1 ? field_length : dot_pos
    if cur_integer_part_length > a:max_field_components_lens[1]
        let a:max_field_components_lens[1] = cur_integer_part_length
    endif
    " Here cur_fractional_part_length includes the leading dot too.
    let cur_fractional_part_length = dot_pos == -1 ? 0 : field_length - dot_pos
    if cur_fractional_part_length > a:max_field_components_lens[2]
        let a:max_field_components_lens[2] = cur_fractional_part_length
    endif
endfunc


func! s:display_progress_bar(cur_progress_pos)
    let progress_display_str = 'Processing... [' . repeat('#', a:cur_progress_pos) . repeat(' ', s:progress_bar_size - a:cur_progress_pos) . ']'
    redraw | echo progress_display_str
endfunc


func! rainbow_csv#adjust_column_stats(column_stats)
    " Ensure that numeric components max widths are consistent with non-numeric (header) width.
    let adjusted_stats = []
    for column_stat in a:column_stats
        if column_stat[1] <= 0
            let column_stat[1] = -1
            let column_stat[2] = -1
        endif
        if column_stat[1] > 0
            " The sum of integer and float parts can be bigger than the max width, e.g. here:
            " value
            " 0.12
            " 1234
            if (column_stat[1] + column_stat[2] > column_stat[0])
                let column_stat[0] = column_stat[1] + column_stat[2]
            endif
            " This is needed when the header is wider than numeric components and/or their sum.
            if (column_stat[0] - column_stat[2] > column_stat[1])
                let column_stat[1] = column_stat[0] - column_stat[2]
            endif
            " Sanity check.
            if (column_stat[0] != column_stat[1] + column_stat[2])
                " Assertion Error, this can never happen.
                return []
            endif
        endif
        call add(adjusted_stats, column_stat)
    endfor
    return adjusted_stats
endfunc


func! s:calc_column_stats(delim, policy, comment_prefix, progress_bucket_size)
    " Result `column_stats` is a list of (max_total_len, max_int_part_len, max_fractional_part_len) tuples.
    let column_stats = []
    let lastLineNo = line("$")
    let is_first_line = 1
    for linenum in range(1, lastLineNo)
        if (a:progress_bucket_size && linenum % a:progress_bucket_size == 0)
            let s:align_progress_bar_position = s:align_progress_bar_position + 1
            call s:display_progress_bar(s:align_progress_bar_position)
        endif
        let line = getline(linenum)
        let [fields, has_warning] = rainbow_csv#preserving_smart_split(line, a:delim, a:policy)
        if a:comment_prefix != '' && stridx(line, a:comment_prefix) == 0
            continue
        endif
        if has_warning
            return [column_stats, linenum]
        endif
        for fnum in range(len(fields))
            let field = rainbow_csv#strip_spaces(fields[fnum])
            if len(column_stats) <= fnum
                call add(column_stats, [0, 0, 0])
            endif
            call rainbow_csv#update_subcomponent_stats(field, is_first_line, column_stats[fnum])
        endfor
        let is_first_line = 0
    endfor
    return [column_stats, 0]
endfunc


func! rainbow_csv#align_field(field, is_first_line, max_field_components_lens, is_last_column)
    " Align field, use max() to avoid negative delta_length which can happen theorethically due to async doc edit.
    let extra_readability_whitespace_length = 1
    let clean_field = rainbow_csv#strip_spaces(a:field)
    let field_length = strdisplaywidth(clean_field)
    if (a:max_field_components_lens[1] == s:non_numeric)
        let delta_length = a:max_field_components_lens[0] - field_length > 0 ? a:max_field_components_lens[0] - field_length : 0
        return a:is_last_column ? clean_field : clean_field . repeat(' ', delta_length + extra_readability_whitespace_length)
    endif
    if a:is_first_line
        let pos = match(clean_field, s:number_regex)
        if pos == -1
            " The line must be a header - align it using max_width rule.
            let delta_length = max([a:max_field_components_lens[0] - field_length, 0])
            return a:is_last_column ? clean_field : clean_field . repeat(' ', delta_length + extra_readability_whitespace_length)
        endif
    endif
    let dot_pos = stridx(clean_field, '.')
    let cur_integer_part_length = dot_pos == -1 ? field_length : dot_pos
    " Here cur_fractional_part_length includes the leading dot too.
    let cur_fractional_part_length = dot_pos == -1 ? 0 : field_length - dot_pos
    let integer_delta_length = a:max_field_components_lens[1] - cur_integer_part_length > 0 ? a:max_field_components_lens[1] - cur_integer_part_length : 0
    let fractional_delta_length = a:max_field_components_lens[2] - cur_fractional_part_length > 0 ? a:max_field_components_lens[2] - cur_fractional_part_length : 0
    let trailing_spaces = a:is_last_column ? '' : repeat(' ', fractional_delta_length + extra_readability_whitespace_length)
    return repeat(' ', integer_delta_length) . clean_field . trailing_spaces
endfunc


func! rainbow_csv#csv_align()
    " The first (statistic) pass of the function takes about 40% of runtime, the second (actual align) pass around 60% of runtime.
    " Numeric-aware logic by itself adds about 50% runtime compared to the basic string-based field width alignment
    " If there are lot of numeric columns this can additionally increase runtime by another 50% or more.
    let show_progress_bar = wordcount()['bytes'] > 200000
    let [delim, policy, comment_prefix] = rainbow_csv#get_current_dialect()
    if policy == 'monocolumn'
        echoerr "RainbowAlign is available only for highlighted CSV files"
        return
    endif
    if policy == 'quoted_rfc'
        echoerr 'RainbowAlign not available for "rfc_csv" filetypes, consider using "csv" instead'
        return
    endif
    let lastLineNo = line("$")
    let progress_bucket_size = (lastLineNo * 2) / s:progress_bar_size " multiply by 2 because we have two passes.
    if !show_progress_bar || progress_bucket_size < 10
        let progress_bucket_size = 0
    endif
    let s:align_progress_bar_position = 0
    let [column_stats, first_failed_line] = s:calc_column_stats(delim, policy, comment_prefix, progress_bucket_size)
    if first_failed_line != 0
        echoerr 'Unable to allign: Inconsistent double quotes at line ' . first_failed_line
        return
    endif
    let column_stats = rainbow_csv#adjust_column_stats(column_stats)
    if !len(column_stats)
        echoerr 'Unable to allign: Internal Rainbow CSV Error'
        return
    endif
    let has_edit = 0
    let is_first_line = 1
    for linenum in range(1, lastLineNo)
        if (progress_bucket_size && linenum % progress_bucket_size == 0)
            let s:align_progress_bar_position = s:align_progress_bar_position + 1
            call s:display_progress_bar(s:align_progress_bar_position)
        endif
        let has_line_edit = 0
        let line = getline(linenum)
        if comment_prefix != '' && stridx(line, comment_prefix) == 0
            continue
        endif
        let fields = rainbow_csv#preserving_smart_split(line, delim, policy)[0]
        for fnum in range(len(fields))
            if fnum >= len(column_stats)
                break " Should never happen
            endif
            let is_last_column = fnum + 1 == len(column_stats)
            let field = rainbow_csv#align_field(fields[fnum], is_first_line, column_stats[fnum], is_last_column)
            if fields[fnum] != field
                let fields[fnum] = field
                let has_line_edit = 1
            endif
        endfor
        if has_line_edit
            let updated_line = join(fields, delim)
            call setline(linenum, updated_line)
            let has_edit = 1
        endif
        let is_first_line = 0
    endfor
    if !has_edit
        echoerr "File is already aligned"
    endif
endfunc


func! rainbow_csv#csv_shrink()
    let [delim, policy, comment_prefix] = rainbow_csv#get_current_dialect()
    if policy == 'monocolumn'
        echoerr "RainbowShrink is available only for highlighted CSV files"
        return
    endif
    if policy == 'quoted_rfc'
        echoerr 'RainbowShrink not available for "rfc_csv" filetypes, consider using "csv" instead'
        return
    endif
    let lastLineNo = line("$")
    let has_edit = 0
    let show_progress_bar = wordcount()['bytes'] > 200000
    let progress_bucket_size = lastLineNo / s:progress_bar_size
    if !show_progress_bar || progress_bucket_size < 10
        let progress_bucket_size = 0
    endif
    let s:align_progress_bar_position = 0
    for linenum in range(1, lastLineNo)
        if (progress_bucket_size && linenum % progress_bucket_size == 0)
            let s:align_progress_bar_position = s:align_progress_bar_position + 1
            call s:display_progress_bar(s:align_progress_bar_position)
        endif
        let has_line_edit = 0
        let line = getline(linenum)
        if comment_prefix != '' && stridx(line, comment_prefix) == 0
            continue
        endif
        let [fields, has_warning] = rainbow_csv#preserving_smart_split(line, delim, policy)
        if has_warning
            echoerr 'Unable to shrink: Inconsistent double quotes at line ' . linenum
            return
        endif
        for fnum in range(len(fields))
            let field = rainbow_csv#strip_spaces(fields[fnum])
            if fields[fnum] != field
                let fields[fnum] = field
                let has_line_edit = 1
            endif
        endfor
        if has_line_edit
            let updated_line = join(fields, delim)
            call setline(linenum, updated_line)
            let has_edit = 1
        endif
    endfor
    if !has_edit
        echoerr "File is already shrinked"
    endif
endfunc


func! rainbow_csv#get_csv_header(delim, policy, comment_prefix)
    if exists("b:cached_virtual_header") && len(b:cached_virtual_header)
        return b:cached_virtual_header
    endif
    let max_lines_to_check = min([line("$"), 20])
    for linenum in range(1, max_lines_to_check)
        let line = getline(linenum)
        if a:comment_prefix != '' && stridx(line, a:comment_prefix) == 0
            continue
        endif
        return rainbow_csv#smart_split(line, a:delim, a:policy)
    endfor
    return []
endfunc


func! rainbow_csv#make_multiline_record_ranges(delim_length, newline_marker, record_fields, start_line, expected_last_line_for_control)
    let record_ranges = []
    let lnum_current = a:start_line
    let pos_in_editor_line = 1
    let next_pos_in_editor_line = 1
    for field_num in range(len(a:record_fields))
        let pos_in_logical_field = 0
        let logical_field_tokens = []
        while 1
            let newline_marker_pos = stridx(a:record_fields[field_num], a:newline_marker, pos_in_logical_field)
            if newline_marker_pos == -1
                break
            endif
            call add(logical_field_tokens, [lnum_current, pos_in_editor_line, lnum_current, pos_in_editor_line + (newline_marker_pos - pos_in_logical_field)])
            let lnum_current += 1
            let pos_in_editor_line = 1
            let next_pos_in_editor_line = 1
            let pos_in_logical_field = newline_marker_pos + len(a:newline_marker)
        endwhile
        let next_pos_in_editor_line += len(a:record_fields[field_num]) - pos_in_logical_field
        if field_num + 1 < len(a:record_fields)
           let next_pos_in_editor_line += a:delim_length
        endif
        " Field token signature: [inclusive_start_line_1_based, inclusive_start_col_1_based, inclusive_end_line_1_based, exclusive_end_col_1_based].
        call add(logical_field_tokens, [lnum_current, pos_in_editor_line, lnum_current, next_pos_in_editor_line])
        call add(record_ranges, logical_field_tokens)
        let pos_in_editor_line = next_pos_in_editor_line
    endfor
    if lnum_current != a:expected_last_line_for_control
        " Sanity check, should never happen.
        return []
    endif
    return record_ranges
endfunc


func! s:is_opening_rfc_line(line_text, delim)
    " The line is oppening if by adding a character (to avoid accidental double double quote) and single double quote at the end we can make it parsable without warning!
    " Some lines can be simultaneously opening and closing, e.g. `",a1,a2` or `a1,a2,"`
    let warning = rainbow_csv#preserving_quoted_split(a:line_text . 'x"', a:delim)[1]
    return !warning
endfunc


func! s:get_neighboring_lines(anchor_line_num)
    let collected_lines = []
    let collected_line_nums = []
    let rfc_local_parse_margin = 20
    let first_line = max([1, a:anchor_line_num - rfc_local_parse_margin])
    let last_line = min([line('$'), a:anchor_line_num + rfc_local_parse_margin])
    for cur_line_num in range(first_line, last_line)
        call add(collected_lines, getline(cur_line_num))
        call add(collected_line_nums, cur_line_num)
    endfor
    return [collected_lines, collected_line_nums]
endfunc


" FIXME add an integration test with cell jumps, both for simple and rfc cases.
func! rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, delim, comment_prefix)
    " FIXME unit test this
    let rfc_line_buffer = []
    let table_ranges = []
    if len(a:neighboring_lines) != len(a:neighboring_line_nums)
        " This should never happen.
        return []
    endif
    " Comment prefix has no effect if inside multiline field, same as in normal languages like Python or JS.
    for line_idx in range(len(a:neighboring_line_nums))
        let cur_line_num = a:neighboring_line_nums[line_idx]
        let line_text = a:neighboring_lines[line_idx]
        if a:comment_prefix != '' && len(rfc_line_buffer) == 0 && stridx(line_text, a:comment_prefix) == 0
            " No use case to add the comment range, just skip the line.
            continue
        endif
        call add(rfc_line_buffer, line_text)
        let has_unbalanced_double_quote = len(split(line_text, '"', 1)) % 2 == 0
        if has_unbalanced_double_quote
            if len(rfc_line_buffer) == 1
                if !s:is_opening_rfc_line(line_text, a:delim)
                    " Parsing error - discard already parsed ranges and start from blank state.
                    let table_ranges = []
                    let rfc_line_buffer = []
                endif
                continue
            endif
        else
            " The current line has balanced double-quotes.
            if len(rfc_line_buffer) > 1
                " This current line is internal in a multi-line record.
                continue
            endif
        endif
        let record_text = join(rfc_line_buffer, "\n")
        let [fields, warning] = rainbow_csv#preserving_smart_split(record_text, a:delim, 'quoted')
        if !warning
            let record_ranges = rainbow_csv#make_multiline_record_ranges(len(a:delim), "\n", fields, cur_line_num - len(rfc_line_buffer) + 1, cur_line_num)
            call add(table_ranges, record_ranges)
        endif
        let rfc_line_buffer = []
    endfor
    return table_ranges
endfunc


func! rainbow_csv#get_field_offset_single_line(fields, delim, field_num)
    let offset = 1
    for fpos in range(a:field_num)
        if fpos >= len(a:fields)
            break
        endif
        let offset += len(a:fields[fpos])
        if fpos + 1 < len(a:fields)
            let offset += len(a:delim)
        endif
    endfor
    return offset
endfunc


func! rainbow_csv#get_field_num_single_line(fields, delim, kb_pos)
    let field_num = 0
    let cpos = len(a:fields[field_num]) + len(a:delim)
    while a:kb_pos > cpos && field_num + 1 < len(a:fields)
        let field_num += 1
        let cpos += len(a:fields[field_num]) + len(a:delim)
    endwhile
    return field_num
endfunc


func! s:cell_jump_simple(direction, delim, policy, comment_prefix)
    let anchor_line_num = line('.')
    let anchor_col_num = col('.')
    let anchor_line = getline('.')
    if a:comment_prefix != '' && stridx(anchor_line, a:comment_prefix) == 0
        return
    endif

    let fields = rainbow_csv#preserving_smart_split(anchor_line, a:delim, a:policy)[0]
    let anchor_field_num = rainbow_csv#get_field_num_single_line(fields, a:delim, anchor_col_num)

    let num_fields = len(fields)

    if a:direction == 'right'
        if anchor_field_num + 1 >= num_fields
            " Can't move further right.
            return
        endif
        let offset = rainbow_csv#get_field_offset_single_line(fields, a:delim, anchor_field_num + 1)
        call cursor(0, offset)
    endif

    if a:direction == 'left'
        if anchor_field_num == 0
            " Can't move further left.
            return
        endif
        let offset = rainbow_csv#get_field_offset_single_line(fields, a:delim, anchor_field_num - 1)
        call cursor(0, offset)
    endif

    if a:direction == 'down' || a:direction == 'up'
        let lastLineNo = line("$")
        let cur_line_num = anchor_line_num
        while 1 
            if a:direction == 'down'
                let cur_line_num += 1
            else
                let cur_line_num -= 1
            endif
            if cur_line_num == 0 || cur_line_num > lastLineNo
                break
            endif
            let cur_line = getline(cur_line_num)
            if a:comment_prefix != '' && stridx(cur_line, a:comment_prefix) == 0
                continue
            endif
            let fields = rainbow_csv#preserving_smart_split(cur_line, a:delim, a:policy)[0]
            let offset = rainbow_csv#get_field_offset_single_line(fields, a:delim, anchor_field_num)
            call cursor(cur_line_num, offset)
            break
        endwhile
    endif
endfunc


func! s:get_relative_record_num_and_field_num_containing_position(table_ranges, line_num, col_num)
    for rr_idx in range(len(a:table_ranges))
        let record_ranges = a:table_ranges[rr_idx]
        for field_index in range(len(record_ranges))
            let logical_field_tokens = record_ranges[field_index]
            for lft in logical_field_tokens
                if a:line_num >= lft[0] && a:line_num <= lft[2] && a:col_num >= lft[1] && a:col_num < lft[3]
                    return [rr_idx, field_index]
                endif
            endfor
        endfor
    endfor
    return [-1, -1]
endfunc


func! s:get_field_coordinates_rfc(table_ranges, relative_record_num, field_num)
    let record_ranges = a:table_ranges[a:relative_record_num]
    let first_logical_field_token = record_ranges[a:field_num][0]
    return [first_logical_field_token[0], first_logical_field_token[1]]
endfunc


func! s:cell_jump_rfc(direction, delim, comment_prefix)
    let cur_line = line('.')
    let cur_col = col('.')
    let [neighboring_lines, neighboring_line_nums] = s:get_neighboring_lines(cur_line)
    let table_ranges = rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, a:delim, a:comment_prefix)
    let [relative_record_num, field_num] = s:get_relative_record_num_and_field_num_containing_position(table_ranges, cur_line, cur_col)
    if field_num == -1 || relative_record_num == -1
        return
    endif
    let num_fields = len(table_ranges[relative_record_num])
    if a:direction == 'right'
        let field_num += 1
    elseif a:direction == 'left'
        let field_num -= 1
    elseif a:direction == 'down' 
        let relative_record_num += 1
    elseif a:direction == 'up'
        let relative_record_num -= 1
    else
        " Should never happen.
        return
    endif

    if (field_num >= num_fields) || (field_num < 0) || (relative_record_num >= len(table_ranges)) || (relative_record_num < 0)
        return
    endif

    let [target_lnum, target_colnum] = s:get_field_coordinates_rfc(table_ranges, relative_record_num, field_num)
    call cursor(target_lnum, target_colnum)
endfunc


func! rainbow_csv#cell_jump(direction)
    let [delim, policy, comment_prefix] = rainbow_csv#get_current_dialect()
    if policy == 'monocolumn'
        return
    endif
    if policy == 'quoted_rfc'
        call s:cell_jump_rfc(a:direction, delim, comment_prefix)
    else
        call s:cell_jump_simple(a:direction, delim, policy, comment_prefix)
    endif
endfunc


func! rainbow_csv#provide_column_info_on_hover()
    let [delim, policy, comment_prefix] = rainbow_csv#get_current_dialect()
    if policy == 'monocolumn'
        return
    endif
    let line = getline('.')

    if comment_prefix != '' && stridx(line, comment_prefix) == 0
        echo ""
        return
    endif

    let header = rainbow_csv#get_csv_header(delim, policy, comment_prefix)
    if !len(header)
        return
    endif
    let fields = []
    let col_num = 0
    let num_fields = 0
    let cur_col = col('.')
    if policy == 'quoted_rfc'
        let cur_line = line('.')
        let [neighboring_lines, neighboring_line_nums] = s:get_neighboring_lines(cur_line)
        let table_ranges = rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, delim, comment_prefix)
        let [_unused_record_num, col_num] = s:get_relative_record_num_and_field_num_containing_position(table_ranges, cur_line, cur_col)
        if col_num == -1
            echo ''
            return
        endif
    else
        let fields = rainbow_csv#preserving_smart_split(line, delim, policy)[0]
        let col_num = rainbow_csv#get_field_num_single_line(fields, delim, cur_col)
        let num_fields = len(fields)
    endif

    let ui_message = printf('Col %s', col_num + 1)
    let col_name = ''
    if col_num < len(header)
        let col_name = header[col_num]
    endif

    let max_col_name = 50
    if len(col_name) > max_col_name
        let col_name = strpart(col_name, 0, max_col_name) . '...'
    endif
    if col_name != ""
        let ui_message = ui_message . printf(', %s', col_name)
    endif
    if len(header) != num_fields
        let ui_message = ui_message . '; WARN: num of fields in Header and this line differs'
    endif
    if exists("b:root_table_name")
        let ui_message = ui_message . printf('; F7: Copy to %s', b:root_table_name)
    endif
    echo ui_message
endfunc


func! s:get_num_columns_if_delimited(delim, policy)
    let lastLineNo = min([line("$"), 100])
    if (lastLineNo < 5)
        return 0
    endif
    let num_fields = 0
    let num_lines_tested = 0
    for linenum in range(1, lastLineNo)
        let line = getline(linenum)
        let comment_prefix = s:get_auto_comment_prefix()
        if comment_prefix != '' && stridx(line, comment_prefix) == 0
            continue
        endif
        let num_lines_tested += 1
        let num_fields_cur = len(rainbow_csv#preserving_smart_split(line, a:delim, a:policy)[0])
        if !num_fields
            let num_fields = num_fields_cur
        endif
        if (num_fields != num_fields_cur || num_fields < 2)
            return 0
        endif
    endfor
    if num_lines_tested < 5
        return 0
    endif
    return num_fields
endfunc


func! s:guess_table_params_from_content()
    let best_dialect = []
    let best_score = 1
    for delim in s:autodetection_delims
        let policy = s:get_auto_policy_for_delim(delim)
        let score = s:get_num_columns_if_delimited(delim, policy)
        if score > best_score
            let best_dialect = [delim, policy]
            let best_score = score
        endif
    endfor
    if best_score > s:max_columns
        return []
    endif
    return best_dialect
endfunc


func! s:guess_table_params_from_content_frequency_based()
    let best_delim = ','
    let best_score = 0
    let lastLineNo = min([line("$"), 50])
    for delim in s:autodetection_delims
        let regex_delim = escape(delim, s:magic_chars)
        let score = 0
        for linenum in range(1, lastLineNo)
            let line = getline(linenum)
            let score += len(split(line, regex_delim, 1)) - 1
        endfor
        if score > best_score
            let best_delim = delim
            let best_score = score
        endif
    endfor
    let best_policy = (best_delim == ',' || best_delim == ';') ? 'quoted' : 'simple'
    return [best_delim, best_policy]
endfunc


func! rainbow_csv#clear_current_buf_content()
    let nl = line("$")
    call cursor(1, 1)
    execute "delete " . nl
endfunc


func! rainbow_csv#generate_tab_statusline(tabstop_val, delim_len, template_fields)
    let result = []
    let space_deficit = 0
    for nf in range(len(a:template_fields))
        let available_space = (a:delim_len + len(a:template_fields[nf]) / a:tabstop_val) * a:tabstop_val
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
        let space_filling = repeat(' ', extra_len + 1)
        if nf + 1 == len(a:template_fields)
            let space_filling = ''
        endif
        call add(result, column_name)
        call add(result, space_filling)
    endfor
    return result
endfunc


func! s:status_escape_string(src)
    " Strings in 'substitute' must follow esoteric rules, see `:help substitute()`
    let result = substitute(a:src, ' ', '\\ ', 'g')
    let result = substitute(result, '"', '\\"', 'g')
    let result = substitute(result, '|', '\\|', 'g')
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
    let [delim, policy, comment_prefix] = rainbow_csv#get_current_dialect()
    if !exists("b:statusline_before")
        let b:statusline_before = &statusline
    endif
    let has_number_column = &number
    let indent = ''
    if has_number_column
        let indent_len = max([len(string(line('$'))) + 1, 4])
        let indent = ' NR' . repeat(' ', indent_len - 3)
    endif
    let cur_line = policy == 'quoted_rfc' ? getline(1) : getline(line('.'))

    if comment_prefix != '' && stridx(cur_line, comment_prefix) == 0
        return
    endif

    let cur_fields = rainbow_csv#preserving_smart_split(cur_line, delim, policy)[0]
    let status_labels = []
    if delim == "\t"
        let status_labels = rainbow_csv#generate_tab_statusline(&tabstop, len(delim), cur_fields)
    else
        let status_labels = rainbow_csv#generate_tab_statusline(1, len(delim), cur_fields)
    endif
    let max_len = winwidth(0)
    let cur_len = len(indent)
    let rb_statusline = '%#status_line_default_hl#' . indent
    let num_columns = len(status_labels) / 2
    for nf in range(num_columns)
        let color_id = nf % s:num_groups
        let column_name = status_labels[nf * 2]
        let space_filling = status_labels[nf * 2 + 1]
        let cur_len += len(column_name) + len(space_filling)
        if cur_len + 1 >= max_len
            break
        endif
        let rb_statusline = rb_statusline . '%#status_color' . color_id . '#' . column_name . '%#status_line_default_hl#' . space_filling
    endfor
    let rb_statusline = s:status_escape_string(rb_statusline)
    execute "setlocal statusline=" . rb_statusline
    redraw!
    augroup StatusDisableGrp
        autocmd CursorMoved * call rainbow_csv#restore_statusline()
    augroup END
endfunc


func! s:get_rb_script_path_for_this_table()
    let rb_script_name = expand("%:t") . ".rbql"
    call s:ensure_storage_exists()
    let rb_script_path = s:rb_storage_dir . '/' . rb_script_name
    return rb_script_path
endfunc


func! s:generate_microlang_syntax(nfields)
    if s:get_meta_language() == "python"
        set ft=python
    else
        set ft=javascript
    endif

    for lnum in range(1, a:nfields)
        let color_num = (lnum - 1) % s:num_groups
        let cmd = 'syntax keyword rbql_color%d a%d'
        exe printf(cmd, color_num, lnum)
        let cmd = 'syntax keyword rbql_color%d b%d'
        exe printf(cmd, color_num, lnum)
    endfor

    syntax match RbCmd "\c \@<=ORDER \+BY \@="
    syntax match RbCmd "\c\(^ *\)\@<=SELECT\( \+TOP \+[0-9]\+\)\?\( \+DISTINCT\( \+COUNT\)\?\)\? \@="
    syntax match RbCmd "\c\(^ *\)\@<=UPDATE\( \+SET\)\? \@="
    syntax match RbCmd "\c \@<=WHERE \@="
    syntax match RbCmd "\c \@<=DESC\( *$\)\@="
    syntax match RbCmd "\c \@<=ASC\( *$\)\@="
    syntax match RbCmd "\c \@<=\(\(\(STRICT \+\)\?LEFT \+\)\|\(INNER \+\)\)\?JOIN \+[^ ]\+ \+ON \@="
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


func! s:make_rbql_demo(num_fields, rbql_welcome_path)
    let select_line = s:make_select_line(a:num_fields)
    let lines = readfile(a:rbql_welcome_path)
    let query_line_num = 1
    for lnum in range(len(lines))
        let patched = substitute(lines[lnum], '###SELECT_PLACEHOLDER###', select_line, "g")
        if patched != lines[lnum]
            let query_line_num = lnum + 1
            let lines[lnum] = patched
        endif
    endfor
    call setline(1, lines)
    call cursor(query_line_num, 1)
    w
endfunc


func! rainbow_csv#select_from_file()
    let [delim, policy, unused_comment_prefix] = rainbow_csv#get_current_dialect()

    let meta_language = s:get_meta_language()

    if meta_language == "python" && !s:EnsurePythonInitialization()
        echoerr "Python interpreter not found. Unable to run in this mode."
        return 0
    endif

    if meta_language == "js" && !s:EnsureJavaScriptInitialization()
        echoerr "Node.js interpreter not found. Unable to run in this mode."
        return 0
    endif

    if exists("b:selected_buf") && buflisted(b:selected_buf)
        execute "bd " . b:selected_buf
    endif

    let buf_number = bufnr("%")
    let buf_path = resolve(expand("%:p"))

    let rb_script_path = s:get_rb_script_path_for_this_table()
    let already_exists = filereadable(rb_script_path)

    let num_fields = len(rainbow_csv#preserving_smart_split(getline(1), delim, policy)[0])

    call rainbow_csv#set_statusline_columns()

    let splitbelow_before = &splitbelow
    set splitbelow
    execute "split " . fnameescape(rb_script_path)
    if bufnr("%") == buf_number
        echoerr "Something went wrong"
        return
    endif
    if !splitbelow_before
        set nosplitbelow
    endif

    let b:table_path = buf_path
    let b:table_buf_number = buf_number
    let b:rainbow_select = 1

    if !exists("g:disable_rainbow_key_mappings")
        nnoremap <buffer> <F5> :RbRun<cr>
    endif

    call s:generate_microlang_syntax(num_fields)
    if !already_exists
        if meta_language == "python"
            let rbql_welcome_py_path = s:script_folder_path . '/rbql_core/welcome_py.rbql'
            call s:make_rbql_demo(num_fields, rbql_welcome_py_path)
        else
            let rbql_welcome_js_path = s:script_folder_path . '/rbql_core/welcome_js.rbql'
            call s:make_rbql_demo(num_fields, rbql_welcome_js_path)
        endif
    endif
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
    echomsg a:msg_header
    echohl None
    for msg in a:msg_lines
        echomsg msg
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


func! s:get_output_format_params(input_delim, input_policy)
    let out_format = exists('g:rbql_output_format') ? g:rbql_output_format : 'input'
    if out_format == 'csv'
        return [',', 'quoted']
    endif
    if out_format == 'tsv'
        return ["\t", 'simple']
    endif
    return [a:input_delim, a:input_policy]
endfunc


func! s:converged_select(table_buf_number, rb_script_path, query_buf_nr)
    let meta_language = s:get_meta_language()

    if meta_language == "python" && !s:EnsurePythonInitialization()
        echoerr "Python interpreter not found. Unable to run in this mode."
        return 0
    endif

    if meta_language == "js" && !s:EnsureJavaScriptInitialization()
        echoerr "Node.js interpreter not found. Unable to run in this mode."
        return 0
    endif

    let rbql_encoding = exists('g:rbql_encoding') ? g:rbql_encoding : 'utf-8'
    if rbql_encoding != 'utf-8' && rbql_encoding != 'latin-1'
        echoerr "Unsupported rbql encoding. Must be 'utf-8' or 'latin-1'"
        return 0
    endif

    let table_filetype = getbufvar(a:table_buf_number, "&syntax")
    let input_dialect = rainbow_csv#ft_to_dialect(table_filetype)
    if !len(input_dialect)
        echoerr "File is not a rainbow table"
        return 0
    endif
    let input_delim = input_dialect[0]
    let input_policy = input_dialect[1]
    let input_comment_prefix = input_dialect[2]

    let table_path = expand("#" . a:table_buf_number . ":p")
    if table_path == ""
        " For unnamed buffers. E.g. can happen for stdin-read buffer: `cat data.tsv | vim -`
        let tmp_file_name = "tmp_table_" .  strftime("%Y_%m_%d_%H_%M_%S") . ".txt"
        let table_path = s:rb_storage_dir . "/" . tmp_file_name
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
    let input_delim_escaped = s:py_source_escape(input_delim)
    let [out_delim, out_policy] = s:get_output_format_params(input_delim, input_policy)
    let out_delim_escaped = s:py_source_escape(out_delim)
    let comment_prefix_escaped = s:py_source_escape(input_comment_prefix)
    let with_headers_py_tf = s:get_rbql_with_headers() ? 'True' : 'False'
    let py_call = 'vim_rbql.run_execute("' . table_path_esc . '", "' . rb_script_path_esc . '", "' . rbql_encoding . '", "' . input_delim_escaped . '", "' . input_policy . '", "' . comment_prefix_escaped . '", "' . out_delim_escaped . '", "' . out_policy . '", ' . with_headers_py_tf . ')'
    if meta_language == "js"
        let rbql_executable_path = s:script_folder_path . '/rbql_core/vim_rbql.js'
        let cmd_args = ['node', shellescape(rbql_executable_path), shellescape(table_path), shellescape(a:rb_script_path), rbql_encoding, shellescape(input_delim), input_policy, shellescape(input_comment_prefix), shellescape(out_delim), out_policy, with_headers_py_tf]
        let cmd = join(cmd_args, ' ')
        let report_content = system(cmd)
        let [psv_query_status, psv_error_report, psv_warning_report, psv_dst_table_path] = rainbow_csv#parse_report(report_content)
    elseif s:system_python_interpreter != ""
        let rbql_executable_path = s:script_folder_path . '/rbql_core/vim_rbql.py'
        let cmd_args = [s:system_python_interpreter, shellescape(rbql_executable_path), shellescape(table_path), shellescape(a:rb_script_path), rbql_encoding, shellescape(input_delim), input_policy, shellescape(input_comment_prefix), shellescape(out_delim), out_policy, with_headers_py_tf]
        let cmd = join(cmd_args, ' ')
        let report_content = system(cmd)
        let [psv_query_status, psv_error_report, psv_warning_report, psv_dst_table_path] = rainbow_csv#parse_report(report_content)
    elseif has("python3")
        exe 'python3 ' . py_call
    elseif s:has_python_27()
        exe 'python ' . py_call
    else
        call s:ShowImportantMessage("Error", ["Python not found, vim must have 'python' or 'python3' feature installed to run in this mode"])
        return 0
    endif

    if psv_query_status != "OK"
        call s:ShowImportantMessage(psv_query_status, [psv_error_report])
        return 0
    endif

    if a:query_buf_nr != -1
        execute "bd! " . a:query_buf_nr
    endif

    if index(split(psv_warning_report, "\n"), 'Output has multiple fields: using "CSV" output format instead of "Monocolumn"') == -1
        call s:update_table_record(psv_dst_table_path, out_delim, out_policy, '@auto_comment_prefix@')
    else
        call s:update_table_record(psv_dst_table_path, ',', 'quoted', '@auto_comment_prefix@')
    endif
    execute "e " . fnameescape(psv_dst_table_path)

    let b:self_path = psv_dst_table_path
    let b:root_table_buf_number = a:table_buf_number
    let b:root_table_name = fnamemodify(table_path, ":t")
    let b:self_buf_number = bufnr("%")
    call setbufvar(a:table_buf_number, 'selected_buf', b:self_buf_number)

    if !exists("g:disable_rainbow_key_mappings")
        nnoremap <buffer> <F7> :call rainbow_csv#copy_file_content_to_buf(b:self_path, b:root_table_buf_number)<cr>
    endif

    if len(psv_warning_report)
        let warnings = split(psv_warning_report, "\n")
        for wnum in range(len(warnings))
            let warnings[wnum] = 'Warning: ' . warnings[wnum]
        endfor
        call s:ShowImportantMessage("Completed with WARNINGS!", warnings)
    endif
    return 1
endfunc


func! rainbow_csv#set_table_name_for_buffer(table_name)
    let table_path = resolve(expand("%:p"))
    let new_record = [a:table_name, table_path]
    let records = s:try_read_index(s:table_names_settings)
    let records = s:update_records(records, a:table_name, new_record)
    if len(records) > 100
        call remove(records, 0)
    endif
    call s:write_index(records, s:table_names_settings)
endfunction


func! s:run_cmd_query(query)
    let rb_script_path = s:get_rb_script_path_for_this_table()
    call writefile([a:query], rb_script_path)
    let table_buf_number = bufnr("%")
    call s:converged_select(table_buf_number, rb_script_path, -1)
endfunction


func! rainbow_csv#run_select_cmd_query(query_string)
    let query = 'SELECT ' . a:query_string
    call s:run_cmd_query(query)
endfunction


func! rainbow_csv#run_update_cmd_query(query_string)
    let query = 'UPDATE ' . a:query_string
    call s:run_cmd_query(query)
endfunction


func! rainbow_csv#finish_query_editing()
    if !exists("b:rainbow_select")
        echoerr "Execute from rainbow query buffer"
        return
    endif
    w
    let rb_script_path = expand("%:p")
    let query_buf_nr = bufnr("%")
    let table_buf_number = b:table_buf_number
    call s:converged_select(table_buf_number, rb_script_path, query_buf_nr)
endfunc


func! rainbow_csv#generate_rainbow_syntax(delim)
    let syntax_lines = []
    let regex_delim = escape(a:delim, s:magic_chars)
    let char_class_delim = s:char_class_escape(a:delim)
    let groupid = s:num_groups - 1
    while groupid >= 0
        let next_group_id = groupid + 1 < s:num_groups ? groupid + 1 : 0
        let cmd = 'syntax match column%d /.\{-}\(%s\|$\)/ nextgroup=column%d'
        call add(syntax_lines, printf(cmd, groupid, regex_delim, next_group_id))
        let groupid -= 1
    endwhile
    return syntax_lines
endfunc


func! rainbow_csv#generate_escaped_rainbow_syntax(delim)
    let syntax_lines = []
    let regex_delim = escape(a:delim, s:magic_chars)
    let char_class_delim = s:char_class_escape(a:delim)
    let groupid = s:num_groups - 1
    while groupid >= 0
        let next_group_id = groupid + 1 < s:num_groups ? groupid + 1 : 0
        let cmd = 'syntax match column%d /.\{-}\(%s\|$\)/ nextgroup=escaped_column%d,column%d'
        call add(syntax_lines, printf(cmd, groupid, regex_delim, next_group_id, next_group_id))
        let cmd = 'syntax match escaped_column%d / *"\([^"]*""\)*[^"]*" *\(%s\|$\)/ nextgroup=escaped_column%d,column%d'
        call add(syntax_lines, printf(cmd, groupid, regex_delim, next_group_id, next_group_id))
        let groupid -= 1
    endwhile
    return syntax_lines
endfunc


func! rainbow_csv#generate_escaped_rfc_rainbow_syntax(delim)
    let syntax_lines = []
    let regex_delim = escape(a:delim, s:magic_chars)
    let char_class_delim = s:char_class_escape(a:delim)
    let groupid = s:num_groups - 1
    while groupid >= 0
        let next_group_id = groupid + 1 < s:num_groups ? groupid + 1 : 0
        let cmd = 'syntax match column%d /.\{-}\(%s\|$\)/ nextgroup=escaped_column%d,column%d'
        call add(syntax_lines, printf(cmd, groupid, regex_delim, next_group_id, next_group_id))
        let cmd = 'syntax match escaped_column%d / *"\(\([^"]\|\n\)*""\)*\([^"]\|\n\)*" *\(%s\|$\)/ nextgroup=escaped_column%d,column%d'
        call add(syntax_lines, printf(cmd, groupid, regex_delim, next_group_id, next_group_id))
        let groupid -= 1
    endwhile
    return syntax_lines
endfunc


func! rainbow_csv#generate_whitespace_syntax()
    let syntax_lines = []
    let groupid = s:num_groups - 1
    while groupid >= 0
        let next_group_id = groupid + 1 < s:num_groups ? groupid + 1 : 0
        let cmd = 'syntax match column%d / *.\{-}\(  *\|$\)/ nextgroup=column%d'
        call add(syntax_lines, printf(cmd, groupid, next_group_id))
        let groupid -= 1
    endwhile
    return syntax_lines
endfunc


func! rainbow_csv#do_set_rainbow_filetype(rainbow_ft)
    let b:originial_ft = &ft
    execute "set ft=" . a:rainbow_ft
endfunc


func! rainbow_csv#set_rainbow_filetype(delim, policy, comment_prefix)
    let rainbow_ft = rainbow_csv#dialect_to_ft(a:delim, a:policy, a:comment_prefix)
    if match(rainbow_ft, 'rcsv') == 0
        call rainbow_csv#ensure_syntax_exists(rainbow_ft, a:delim, a:policy, a:comment_prefix)
    endif
    call rainbow_csv#do_set_rainbow_filetype(rainbow_ft)
endfunc


func! rainbow_csv#buffer_disable_rainbow_features()
    let b:rainbow_features_enabled = 0
    augroup RainbowHintGrp
        autocmd! CursorMoved <buffer>
    augroup END
    if !exists("g:disable_rainbow_key_mappings")
        unmap <buffer> <F5>
    endif
endfunc


func! rainbow_csv#buffer_enable_rainbow_features()
    if rainbow_csv#is_rainbow_table_or_was_just_disabled()
        call rainbow_csv#buffer_disable_rainbow_features()
    endif

    let b:rainbow_features_enabled = 1

    set laststatus=2

    if &compatible == 1
        set nocompatible
    endif

    " maybe use setlocal number ?
    set number

    if !exists("g:disable_rainbow_key_mappings")
        nnoremap <buffer> <F5> :RbSelect<cr>
    endif

    highlight status_line_default_hl ctermbg=black guibg=black

    cnoreabbrev <expr> <buffer> Select rainbow_csv#set_statusline_columns() == "dummy" ? 'Select' : 'Select'
    cnoreabbrev <expr> <buffer> select rainbow_csv#set_statusline_columns() == "dummy" ? 'Select' : 'Select'
    cnoreabbrev <expr> <buffer> SELECT rainbow_csv#set_statusline_columns() == "dummy" ? 'Select' : 'Select'

    cnoreabbrev <expr> <buffer> Update rainbow_csv#set_statusline_columns() == "dummy" ? 'Update' : 'Update'
    cnoreabbrev <expr> <buffer> update rainbow_csv#set_statusline_columns() == "dummy" ? 'Update' : 'Update'
    cnoreabbrev <expr> <buffer> UPDATE rainbow_csv#set_statusline_columns() == "dummy" ? 'Update' : 'Update'

    augroup RainbowHintGrp
        autocmd! CursorMoved <buffer>
        if !exists("g:disable_rainbow_hover") || g:disable_rainbow_hover == 0
            autocmd CursorMoved <buffer> call rainbow_csv#provide_column_info_on_hover()
        endif
    augroup END
endfunc


function! rainbow_csv#get_visual_selection()
    " Taken from here: https://stackoverflow.com/a/6271254/2898283
    let [line_start, column_start] = getpos("'<")[1:2]
    let [line_end, column_end] = getpos("'>")[1:2]
    let lines = getline(line_start, line_end)
    if len(lines) == 0
        return ''
    endif
    let lines[-1] = lines[-1][: column_end - (&selection == 'inclusive' ? 1 : 2)]
    let lines[0] = lines[0][column_start - 1:]
    return join(lines, "\n")
endfunction


func! rainbow_csv#manual_set(arg_policy, is_multidelim)
    if a:is_multidelim
        let delim = rainbow_csv#get_visual_selection()
        let policy = 'simple'
        let max_delim_len = exists('g:max_multichar_delim_len') ? g:max_multichar_delim_len : 10
        if len(delim) > max_delim_len
            echoerr 'Multicharater delimiter is too long. Adjust g:max_multichar_delim_len or use a different separator'
            return
        endif
    else
        let delim = getline('.')[col('.') - 1]
        let policy = a:arg_policy
    endif
    if policy == 'auto'
        let policy = s:get_auto_policy_for_delim(delim)
    endif
    if delim == '"' && policy == 'quoted'
        echoerr 'Double quote delimiter is incompatible with "quoted" policy'
        return
    endif
    call rainbow_csv#set_rainbow_filetype(delim, policy, s:get_auto_comment_prefix())
    let table_path = resolve(expand("%:p"))
    call s:update_table_record(table_path, delim, policy, '@auto_comment_prefix@')
endfunc


func! rainbow_csv#manual_disable()
    if rainbow_csv#is_rainbow_table()
        let original_filetype = exists("b:originial_ft") ? b:originial_ft : ''
        " The command below: set ft =...  will implicitly trigger syntax update -> rainbow_csv#handle_syntax_change() -> rainbow_csv#buffer_disable_rainbow_features()
        execute "set ft=" . original_filetype
    endif
endfunc


func! rainbow_csv#manual_set_comment_prefix(is_multi_comment_prefix)
    let [delim, policy, _comment_prefix_old] = rainbow_csv#get_current_dialect()
    if policy == 'monocolumn'
        echoerr "Rainbow comment prefix can only be set for highlighted CSV files"
        return
    endif

    if a:is_multi_comment_prefix
        let comment_prefix = rainbow_csv#get_visual_selection()
        let max_prefix_len = exists('g:max_comment_prefix_len') ? g:max_comment_prefix_len : 5
        if len(comment_prefix) > max_prefix_len
            echoerr 'Multicharater comment prefix is too long. Adjust g:max_comment_prefix_len or use a different comment prefix'
            return
        endif
    else
        let comment_prefix = getline('.')[col('.') - 1]
    endif
    if len(comment_prefix) <= 0
        echoerr 'Comment prefix can not be empty'
        return
    endif
    call rainbow_csv#set_rainbow_filetype(delim, policy, comment_prefix)
    let table_path = resolve(expand("%:p"))
    call s:update_table_record(table_path, delim, policy, comment_prefix)
endfunc


func! rainbow_csv#manual_disable_comment_prefix()
    let [delim, policy, _comment_prefix_old] = rainbow_csv#get_current_dialect()
    call rainbow_csv#set_rainbow_filetype(delim, policy, '')
    let table_path = resolve(expand("%:p"))
    call s:update_table_record(table_path, delim, policy, '')
endfunc


func! rainbow_csv#handle_new_file()
    let table_extension = expand('%:e')
    if table_extension == 'tsv' || table_extension == 'tab'
        call rainbow_csv#do_set_rainbow_filetype('tsv')
        return
    endif

    let table_params = s:guess_table_params_from_content()
    if !len(table_params) && table_extension == 'csv'
        let table_params = s:guess_table_params_from_content_frequency_based()
    endif
    if !len(table_params)
        let b:rainbow_features_enabled = 0
        return
    endif
    call rainbow_csv#set_rainbow_filetype(table_params[0], table_params[1], s:get_auto_comment_prefix())
endfunc


func! rainbow_csv#handle_buffer_enter()
    if !exists("s:num_groups")
        " Just to make sure that syntax was generated.
        call rainbow_csv#init_rb_color_groups()
    endif

    if exists("b:rainbow_features_enabled")
        if b:rainbow_features_enabled
            " This is a workaround against Vim glitches. sometimes it 'forgets' to highlight the file even when ft=csv, see https://stackoverflow.com/questions/14779299/syntax-highlighting-randomly-disappears-during-file-saving
            " From the other hand it can discard highlight ":hi ... " rules from user config, so let's disable this for now
            " syntax enable
            " another hack instead of `syntax enable` which is kind of global
            " Maybe it is better to power-cycle syntax instead of ft?
            let ft_power_cycle = &ft
            execute "set ft=" . ft_power_cycle
        endif
        return
    endif

    if exists("b:current_syntax")
        " This is actually problematic for files with first comment line with # comment prefix e.g. this file: RBQL/test/csv_files/university_ranking_with_comments.csv
        " Because this check happens before index search the decision to highlight as rainbow will not be remembered on file reopen
        " On the other hand this improves performance - we don't have to read the index file on each buffer enter.
        " We can actually do a hybrid approach - set a flag on buffer that it has already been checked + keep the cached version of the index file in Vim's memory
        " TODO consider doing this ^
        "
        " Actually it is desirable to handle this even on the very first file open. For some reason Vim treats files with non - .txt extension and '#' as the first character as 'conf' files
        return
    endif

    let table_path = resolve(expand("%:p"))
    let table_params = s:get_table_record(table_path)
    if len(table_params)
        " 'disabled' is just for backward compatibility, it is an alias to 'monocolumn'
        if table_params[1] == 'disabled' || table_params[1] == 'monocolumn'
            let b:rainbow_features_enabled = 0
        else
            call rainbow_csv#set_rainbow_filetype(table_params[0], table_params[1], table_params[2])
        endif
        return
    endif

    if exists("g:disable_rainbow_csv_autodetect") && g:disable_rainbow_csv_autodetect
        return
    endif

    call rainbow_csv#handle_new_file()
endfunc


func! rainbow_csv#handle_syntax_change()
    let [delim, policy, comment_prefix] = rainbow_csv#get_current_dialect()
    if policy == 'monocolumn' " If the new filetype is no longer rainbow:
        if rainbow_csv#is_rainbow_table_or_was_just_disabled()
            call rainbow_csv#buffer_disable_rainbow_features()
            let table_path = resolve(expand("%:p"))
            call s:update_table_record(table_path, '', 'monocolumn', '')
        endif
        return
    endif
    if !exists("s:num_groups")
        " Just to make sure that syntax was generated.
        call rainbow_csv#init_rb_color_groups()
    endif

    " We don't want to update_table_record() here because ft change could have been triggered by autodetection
    " Even if it is manual, Vim itself doesn't save manual ft=<lang> selections, so if this plugin does it but only for csv, this could be a little inconsistent
    " But we can actually do this: in autodetection set a special flag and immediately unset it here. If the flag is not set, than it was manual switch and we need to remember the choice
    call rainbow_csv#buffer_enable_rainbow_features()
    let b:cached_virtual_header = s:read_virtual_header(delim, policy)
endfunc
