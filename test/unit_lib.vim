let g:rbql_test_log_records = []


func! AssertEqual(lhs, rhs)
    if a:lhs != a:rhs
        let msg = 'FAIL. Equal assertion failed: "' . string(a:lhs) . '" != "' . string(a:rhs) . '"'
        throw msg
    endif
endfunc


func! AssertTrue(expr, error_msg)
    if !a:expr
        let msg = 'FAIL. True assertion failed: ' . a:error_msg
        throw msg
    endif
endfunc


func! TestAlignStats()
    " Previous fields are numbers but the current one is not - mark the column as non-numeric.
    let field = 'foobar'
    let is_first_line = 0
    let field_components = [5, 2, 3]
    call rainbow_csv#update_subcomponent_stats(field, is_first_line, field_components)
    call AssertEqual(field_components, [6, -1, -1])

    " The field is non-numeric but it is at the first line so could be a header - do not mark the column as non-numeric just yet.
    let field = 'foobar'
    let is_first_line = 1
    let field_components = [0, 0, 0]
    call rainbow_csv#update_subcomponent_stats(field, is_first_line, field_components)
    call AssertEqual(field_components, [6, 0, 0])

    " The field is a number but the column is already marked as non-numeric so we just update the max string width.
    let field = '100000'
    let is_first_line = 0
    let field_components = [2, -1, -1]
    call rainbow_csv#update_subcomponent_stats(field, is_first_line, field_components)
    call AssertEqual(field_components, [6, -1, -1])

    " Empty field should not mark a potentially numeric column as non-numeric.
    let field = ''
    let is_first_line = 0
    let field_components = [5, 2, 3]
    call rainbow_csv#update_subcomponent_stats(field, is_first_line, field_components)
    call AssertEqual(field_components, [5, 2, 3])

    " The field doesn't change stats because all of 3 components are smaller than the current maximums.
    let field = '100.3'
    let is_first_line = 0
    let field_components = [7, 4, 3]
    call rainbow_csv#update_subcomponent_stats(field, is_first_line, field_components)
    call AssertEqual(field_components, [7, 4, 3])

    " Integer update example.
    let field = '100000'
    let is_first_line = 0
    let field_components = [5, 2, 3]
    call rainbow_csv#update_subcomponent_stats(field, is_first_line, field_components)
    call AssertEqual(field_components, [6, 6, 3])

    " Float update example.
    let field = '1000.23'
    let is_first_line = 0
    let field_components = [3, 3, 0]
    call rainbow_csv#update_subcomponent_stats(field, is_first_line, field_components)
    call AssertEqual(field_components, [7, 4, 3])
endfunc


func! TestGetFieldOffsetSingleLine()
"12,,12,,,,12,
    let fields = ["12", "", "12", "", "", "", "12", ""]
    let delim = ","
    let field_num = 0
    call AssertEqual(1, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 1
    call AssertEqual(4, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 2
    call AssertEqual(5, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 3
    call AssertEqual(8, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 4
    call AssertEqual(9, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 6
    call AssertEqual(11, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 7
    call AssertEqual(14, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 1000
    call AssertEqual(14, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))

"12
    let fields = ["12"]
    let delim = ","
    let field_num = 0
    call AssertEqual(1, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 1
    call AssertEqual(3, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 10
    call AssertEqual(3, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))


    " Test empty line.
    let fields = [""]
    let delim = ","
    let field_num = 0
    call AssertEqual(1, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 1
    call AssertEqual(1, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
    let field_num = 10
    call AssertEqual(1, rainbow_csv#get_field_offset_single_line(fields, delim, field_num))
endfunc


func! TestParseDocumentRangeRfc()
    " Trivial case - no records identified.
    let neighboring_lines = []
    let neighboring_line_nums = []
    let delim = ','
    let comment_prefix = '#'
    let table_ranges = rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, delim, comment_prefix)
    call AssertEqual([], table_ranges)

    " Trivial case - all comments.
    let neighboring_lines = ['# comment', '# comment', '# comment']
    let neighboring_line_nums = [1, 2, 3]
    let delim = ','
    let comment_prefix = '#'
    let table_ranges = rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, delim, comment_prefix)
    call AssertEqual([], table_ranges)

    " Comment line inside a multiline record is not treated as a comment!
    let neighboring_lines = [',"ab', '# not a comment', 'c",de']
    let neighboring_line_nums = [1, 2, 3]
    let delim = ','
    let comment_prefix = '#'
    let table_ranges = rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, delim, comment_prefix)
    let expected_table_ranges = []
    call add(expected_table_ranges, [[[1, 1, 1, 2]], [[1, 2, 1, 5], [2, 1, 2, 16], [3, 1, 3, 4]], [[3, 4, 3, 6]]])
    call AssertEqual(expected_table_ranges, table_ranges)

    " Simple case: two single-line records.
    let neighboring_lines = ['1234,1', '1234,1']
    let neighboring_line_nums = [1, 2]
    let delim = ','
    let comment_prefix = '#'
    let table_ranges = rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, delim, comment_prefix)
    let expected_table_ranges = []
    call add(expected_table_ranges, [[[1, 1, 1, 6]], [[1, 6, 1, 7]]])
    call add(expected_table_ranges, [[[2, 1, 2, 6]], [[2, 6, 2, 7]]])
    call AssertEqual(expected_table_ranges, table_ranges)

    " Two well-formed records, first one is multiline.
    let neighboring_lines = ['12,"34', '56,78', '9",ab', 'cd,']
    let neighboring_line_nums = [1, 2, 3, 4]
    let delim = ','
    let comment_prefix = '#'
    let table_ranges = rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, delim, comment_prefix)
    let expected_table_ranges = []
    call add(expected_table_ranges, [[[1, 1, 1, 4]], [[1, 4, 1, 7], [2, 1, 2, 6], [3, 1, 3, 4]], [[3, 4, 3, 6]]])
    call add(expected_table_ranges, [[[4, 1, 4, 4]], [[4, 4, 4, 4]]])
    call AssertEqual(expected_table_ranges, table_ranges)

    " Mutiline record doesn't close.
    let neighboring_lines = ['12,"34,56"', 'ab,cd', 'ab,"cd', 'ab,cd', 'ab,cd']
    let neighboring_line_nums = [1, 2, 3, 4, 5]
    let delim = ','
    let comment_prefix = '#'
    let table_ranges = rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, delim, comment_prefix)
    let expected_table_ranges = []
    call add(expected_table_ranges, [[[1, 1, 1, 4]], [[1, 4, 1, 11]]])
    call add(expected_table_ranges, [[[2, 1, 2, 4]], [[2, 4, 2, 6]]])
    call AssertEqual(expected_table_ranges, table_ranges)

    " Mutiline record doesn't open - only closing within the range.
    let neighboring_lines = ['ab,cd', 'ab,cd', 'ab",cd', '12,"34,56"', 'ab,cd']
    let neighboring_line_nums = [1, 2, 3, 4, 5]
    let delim = ','
    let comment_prefix = '#'
    let table_ranges = rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, delim, comment_prefix)
    let expected_table_ranges = []
    call add(expected_table_ranges, [[[4, 1, 4, 4]], [[4, 4, 4, 11]]])
    call add(expected_table_ranges, [[[5, 1, 5, 4]], [[5, 4, 5, 6]]])
    call AssertEqual(expected_table_ranges, table_ranges)

    " Handling inconsistent args - different number of lines and line nums.
    let neighboring_lines = ['1234,1', '1234,1']
    let neighboring_line_nums = [1, 2, 3]
    let delim = ','
    let comment_prefix = '#'
    let table_ranges = rainbow_csv#parse_document_range_rfc(neighboring_lines, neighboring_line_nums, delim, comment_prefix)
    let expected_table_ranges = []
    call AssertEqual(expected_table_ranges, table_ranges)
endfunc


func! Test_get_relative_record_num_and_field_num_containing_position()
    " Test empty table_ranges.
    let table_ranges = []
    let line_num = 1
    let col_num = 1
    let [relative_record_num, field_num] = rainbow_csv#get_relative_record_num_and_field_num_containing_position(table_ranges, line_num, col_num)
    call AssertEqual(-1, relative_record_num)
    call AssertEqual(-1, field_num)

"12,34
"# hello
"12,34
    
    " Inside comment line.
    let table_ranges = []
    call add(table_ranges, [[[1, 1, 1, 4]], [[1, 4, 1, 7]]])
    call add(table_ranges, [[[3, 1, 3, 4]], [[3, 4, 3, 7]]])
    let line_num = 2
    let col_num = 1
    let [relative_record_num, field_num] = rainbow_csv#get_relative_record_num_and_field_num_containing_position(table_ranges, line_num, col_num)
    call AssertEqual(-1, relative_record_num)
    call AssertEqual(-1, field_num)

    " Past-the-end column number after the last field in line/record.
    let table_ranges = []
    call add(table_ranges, [[[1, 1, 1, 4]], [[1, 4, 1, 7]]])
    call add(table_ranges, [[[3, 1, 3, 4]], [[3, 4, 3, 7]]])
    let line_num = 3
    let col_num = 100
    let [relative_record_num, field_num] = rainbow_csv#get_relative_record_num_and_field_num_containing_position(table_ranges, line_num, col_num)
    call AssertEqual(1, relative_record_num)
    call AssertEqual(1, field_num)

    " Last character in field (comma) in a single-line record.
    let table_ranges = []
    call add(table_ranges, [[[1, 1, 1, 4]], [[1, 4, 1, 7]]])
    call add(table_ranges, [[[3, 1, 3, 4]], [[3, 4, 3, 7]]])
    let line_num = 3
    let col_num = 3
    let [relative_record_num, field_num] = rainbow_csv#get_relative_record_num_and_field_num_containing_position(table_ranges, line_num, col_num)
    call AssertEqual(1, relative_record_num)
    call AssertEqual(0, field_num)

    " First character in field in a single-line record.
    let table_ranges = []
    call add(table_ranges, [[[1, 1, 1, 4]], [[1, 4, 1, 7]]])
    call add(table_ranges, [[[3, 1, 3, 4]], [[3, 4, 3, 7]]])
    let line_num = 3
    let col_num = 4
    let [relative_record_num, field_num] = rainbow_csv#get_relative_record_num_and_field_num_containing_position(table_ranges, line_num, col_num)
    call AssertEqual(1, relative_record_num)
    call AssertEqual(1, field_num)

"12,"34
"56,78
"9",ab
"cd,
    
    " Inside the first multiline field.
    let table_ranges = []
    call add(table_ranges, [[[1, 1, 1, 4]], [[1, 4, 1, 7], [2, 1, 2, 6], [3, 1, 3, 4]], [[3, 4, 3, 6]]])
    call add(table_ranges, [[[4, 1, 4, 4]], [[4, 4, 4, 4]]])
    let line_num = 2
    let col_num = 5
    let [relative_record_num, field_num] = rainbow_csv#get_relative_record_num_and_field_num_containing_position(table_ranges, line_num, col_num)
    call AssertEqual(0, relative_record_num)
    call AssertEqual(1, field_num)

    " Past-the-end column number inside the first multiline field.
    let table_ranges = []
    call add(table_ranges, [[[1, 1, 1, 4]], [[1, 4, 1, 7], [2, 1, 2, 6], [3, 1, 3, 4]], [[3, 4, 3, 6]]])
    call add(table_ranges, [[[4, 1, 4, 4]], [[4, 4, 4, 4]]])
    let line_num = 2
    let col_num = 100
    let [relative_record_num, field_num] = rainbow_csv#get_relative_record_num_and_field_num_containing_position(table_ranges, line_num, col_num)
    call AssertEqual(0, relative_record_num)
    call AssertEqual(1, field_num)
endfunc


func! TestGetFieldNumSingleLine()
    let fields = ["123", "", "1234", "", "", "", "56"]
    let delim = ","
    let kb_pos = 3
    call AssertEqual(0, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 4
    call AssertEqual(0, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 5
    call AssertEqual(1, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 6
    call AssertEqual(2, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 14
    call AssertEqual(6, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 100500
    call AssertEqual(6, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))

"0   1  2      3  4
"1~#~~#~1234~#~~#~~#~
    let fields = ["1", "", "1234", "", ""]
    let delim = "~#~"
    let kb_pos = 4
    call AssertEqual(0, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 5
    call AssertEqual(1, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 6
    call AssertEqual(1, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 7
    call AssertEqual(1, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 8
    call AssertEqual(2, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 14
    call AssertEqual(2, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 15
    call AssertEqual(3, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
    let kb_pos = 1000
    call AssertEqual(4, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))

    " Test empty line.
    let fields = [""]
    let delim = ","
    let kb_pos = 1
    call AssertEqual(0, rainbow_csv#get_field_num_single_line(fields, delim, kb_pos))
endfunc


func! TestMakeMultilineRecordRanges()
    let delim_length = 1
    let record_fields = ["1234567", "123\n45\n67", "123456", "123", "123\n456"]
    let start_line = 10
    let expected_last_line_for_control = 13
    let record_ranges = rainbow_csv#make_multiline_record_ranges(delim_length, "\n", record_fields, start_line, expected_last_line_for_control)
    call AssertEqual([[[10, 1, 10, 9]], [[10, 9, 10, 12], [11, 1, 11, 3], [12, 1, 12, 4]], [[12, 4, 12, 11]], [[12, 11, 12, 15]], [[12, 15, 12, 18], [13, 1, 13, 4]]], record_ranges)

    " Wrong list line for control.
    let bad_expected_last_line_for_control = 12
    let record_ranges = rainbow_csv#make_multiline_record_ranges(delim_length, "\n", record_fields, start_line, bad_expected_last_line_for_control)
    call AssertEqual([], record_ranges)

    " A lot of empty lines in the middle of the field.
    let record_fields = ["1234567", "123\n\n\n\n45", "123"]
    let expected_last_line_for_control = 14
    let record_ranges = rainbow_csv#make_multiline_record_ranges(delim_length, "\n", record_fields, start_line, expected_last_line_for_control)
    call AssertEqual([[[10, 1, 10, 9]], [[10, 9, 10, 12], [11, 1, 11, 1], [12, 1, 12, 1], [13, 1, 13, 1], [14, 1, 14, 4]], [[14, 4, 14, 7]]], record_ranges)

    " Many empty fields, same line (no newlines).
    let record_fields = ["1234", "", "", "", "123"]
    let expected_last_line_for_control = 10
    let record_ranges = rainbow_csv#make_multiline_record_ranges(delim_length, "\n", record_fields, start_line, expected_last_line_for_control)
    call AssertEqual([[[10, 1, 10, 6]], [[10, 6, 10, 7]], [[10, 7, 10, 8]], [[10, 8, 10, 9]], [[10, 9, 10, 12]]], record_ranges)

    " Single entry record.
    let record_fields = ["1234"]
    let expected_last_line_for_control = 10
    let record_ranges = rainbow_csv#make_multiline_record_ranges(delim_length, "\n", record_fields, start_line, expected_last_line_for_control)
    call AssertEqual([[[10, 1, 10, 5]]], record_ranges)

    " Record for an empty line.
    let record_fields = [""]
    let expected_last_line_for_control = 10
    let record_ranges = rainbow_csv#make_multiline_record_ranges(delim_length, "\n", record_fields, start_line, expected_last_line_for_control)
    call AssertEqual([[[10, 1, 10, 1]]], record_ranges)
endfunc


func! TestAdjustColumnStats()
    " Not a numeric column, adjustment is NOOP.
    let max_components_lens = [10, -1, -1]
    let adjusted_components = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    call AssertEqual([10, -1, -1,], adjusted_components)

    " This is possisble with a single-line file.
    let max_components_lens = [10, 0, 0]
    let adjusted_components = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    call AssertEqual([10, -1, -1,], adjusted_components)

    " Header is smaller than the sum of the numeric components.
    " value
    " 0.12
    " 1234
    let max_components_lens = [5, 4, 3]
    let adjusted_components = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    call AssertEqual([7, 4, 3,], adjusted_components)

    " Header is bigger than the sum of the numeric components.
    let max_components_lens = [10, 4, 3]
    let adjusted_components = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    call AssertEqual([10, 7, 3,], adjusted_components)
endfunc


func! TestFieldAlign()
    " Align field in non-numeric non-last column.
    let field = 'foobar'
    let is_first_line = 0
    let max_components_lens = [10, -1, -1]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 0
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('foobar     ', aligned_field)

    " Align field in non-numeric last column.
    let field = 'foobar'
    let is_first_line = 0
    let max_components_lens = [10, -1, -1]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 1
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('foobar', aligned_field)

    " Align non-numeric first line (potentially header) field in numeric column.
    let field = 'foobar'
    let is_first_line = 1
    let max_components_lens = [10, 4, 6]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 0
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('foobar     ', aligned_field)

    " Align numeric first line (potentially header) field in numeric column.
    let field = '10.1'
    let is_first_line = 1
    let max_components_lens = [10, 4, 6]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 0
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('  10.1     ', aligned_field)

    " Align numeric field in non-numeric column (first line).
    let field = '10.1'
    let is_first_line = 1
    let max_components_lens = [10, -1, -1]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 0
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('10.1       ', aligned_field)

    " Align numeric field in non-numeric column (not first line).
    let field = '10.1'
    let is_first_line = 0
    let max_components_lens = [10, -1, -1]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 0
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('10.1       ', aligned_field)

    " Align numeric float in numeric non-last column.
    let field = '10.1'
    let is_first_line = 0
    let max_components_lens = [10, 4, 6]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 0
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('  10.1     ', aligned_field)

    " Align numeric float in numeric last column.
    let field = '10.1'
    let is_first_line = 0
    let max_components_lens = [10, 4, 6]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 1
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('  10.1', aligned_field)

    " Align numeric integer in numeric non-last column.
    let field = '1000'
    let is_first_line = 0
    let max_components_lens = [10, 4, 6]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 0
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('1000       ', aligned_field)

    " Align numeric integer in numeric last column.
    let field = '1000'
    let is_first_line = 0
    let max_components_lens = [10, 4, 6]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 1
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('1000', aligned_field)

    " Align numeric integer in numeric (integer) column.
    let field = '1000'
    let is_first_line = 0
    let max_components_lens = [4, 4, 0]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 0
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('1000 ', aligned_field)

    " Align numeric integer in numeric (integer) column dominated by header width.
    let field = '1000'
    let is_first_line = 0
    let max_components_lens = [6, 4, 0]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 0
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('  1000 ', aligned_field)

    " Align numeric float in numeric column dominated by header width.
    let field = '10.1'
    let is_first_line = 0
    let max_components_lens = [12, 4, 6]
    let max_components_lens = rainbow_csv#adjust_column_stats([max_components_lens])[0]
    let is_last_column = 0
    let aligned_field = rainbow_csv#align_field(field, is_first_line, max_components_lens, is_last_column)
    call AssertEqual('    10.1     ', aligned_field)
endfunc


func! TestWhitespaceSplit()
    call AssertEqual(rainbow_csv#whitespace_split('  hello   world ', 0), ['hello', 'world'])
    call AssertEqual(rainbow_csv#whitespace_split('   ', 0), [''])
    call AssertEqual(rainbow_csv#whitespace_split('   ', 1), ['   '])
    call AssertEqual(rainbow_csv#whitespace_split('  hello   world ', 0), ['hello', 'world'])
    call AssertEqual(rainbow_csv#whitespace_split('hello   world ', 0), ['hello', 'world'])
    call AssertEqual(rainbow_csv#whitespace_split('   hello   world', 0), ['hello', 'world'])
    call AssertEqual(rainbow_csv#whitespace_split(' hello  world ', 1), [' hello', ' world '])
    call AssertEqual(rainbow_csv#whitespace_split(' hello  world', 1), [' hello', ' world'])
    call AssertEqual(rainbow_csv#whitespace_split('hello  world ', 1), ['hello', ' world '])
    call AssertEqual(rainbow_csv#whitespace_split(' a ', 1), [' a '])
    call AssertEqual(rainbow_csv#whitespace_split('a ', 1), ['a '])
    call AssertEqual(rainbow_csv#whitespace_split(' a', 1), [' a'])
    call AssertEqual(rainbow_csv#whitespace_split(' a ', 0), ['a'])
    call AssertEqual(rainbow_csv#whitespace_split('a ', 0), ['a'])
    call AssertEqual(rainbow_csv#whitespace_split(' a', 0), ['a'])
    call AssertEqual(rainbow_csv#whitespace_split(' aa hello  world   bb ', 1), [' aa', 'hello', ' world', '  bb '])
    call AssertEqual(rainbow_csv#whitespace_split(' aa hello  world   bb ', 0), ['aa', 'hello', 'world', 'bb'])
endfunc


func! RunUnitTests()
    call add(g:rbql_test_log_records, 'Starting Test: Statusline')

    "10,a,b,20000,5
    "a1 a2 a3 a4  a5
    let test_stln = rainbow_csv#generate_tab_statusline(1, 1, ['10', 'a', 'b', '20000', '5'])
    let test_stln_str = join(test_stln, '')
    let canonic_stln = 'a1 a2 a3 a4  a5'
    call AssertEqual(test_stln_str, canonic_stln)

    "10  a   b   20000   5
    "a1  a2  a3  a4      a5
    let test_stln = rainbow_csv#generate_tab_statusline(4, 1, ['10', 'a', 'b', '20000', '5'])
    let test_stln_str = join(test_stln, '')
    let canonic_stln = 'a1  a2  a3  a4      a5'
    call AssertEqual(test_stln_str, canonic_stln)

    call AssertEqual(rainbow_csv#preserving_quoted_split('   ', ',')[0], ['   '])
    call AssertEqual(rainbow_csv#quoted_split('   ', ','), [''])
    call AssertEqual(rainbow_csv#quoted_split(' "  abc  " , abc , bbb ', ','), ['  abc  ', 'abc', 'bbb'])

    let test_cases = []
    call add(test_cases, ['abc', 'abc'])
    call add(test_cases, ['abc,', 'abc;'])
    call add(test_cases, [',abc', ';abc'])
    call add(test_cases, ['abc,cdef', 'abc;cdef'])
    call add(test_cases, ['"abc",cdef', '"abc";cdef'])
    call add(test_cases, ['abc,"cdef"', 'abc;"cdef"'])
    call add(test_cases, ['"a,bc",cdef', '"a,bc";cdef'])
    call add(test_cases, ['abc,"c,def"', 'abc;"c,def"'])
    call add(test_cases, [',', ';'])
    call add(test_cases, [', ', '; '])
    call add(test_cases, ['"abc"', '"abc"'])
    call add(test_cases, [',"haha,hoho",', ';"haha,hoho";'])
    call add(test_cases, ['"a,bc","adf,asf","asdf,asdf,","as,df"', '"a,bc";"adf,asf";"asdf,asdf,";"as,df"'])

    call add(test_cases, [' "  abc  " , abc , bbb ', ' "  abc  " ; abc ; bbb '])

    for nt in range(len(test_cases))
        let test_str = join(rainbow_csv#preserving_quoted_split(test_cases[nt][0], ',')[0], ';')
        let canonic_str = test_cases[nt][1]
        call AssertEqual(test_str, canonic_str)
    endfor

    call TestWhitespaceSplit()

    call TestAlignStats()
    call TestFieldAlign()
    call TestAdjustColumnStats()
    call TestMakeMultilineRecordRanges()
    call TestGetFieldNumSingleLine()
    call TestGetFieldOffsetSingleLine()
    call TestParseDocumentRangeRfc()
    call Test_get_relative_record_num_and_field_num_containing_position()
    
    call add(g:rbql_test_log_records, 'Finished Test: Statusline')
endfunc


func! TestSplitRandomCsv()
    "FIXME compare warnings equality too since vim function can now return them
    let lines = readfile('./random_ut.csv')
    for line in lines
        let records = split(line, "\t", 1)
        call AssertEqual(len(records), 3)
        let escaped_entry = records[0]
        let canonic_warning = str2nr(records[1])
        call AssertTrue(canonic_warning == 0 || canonic_warning == 1, 'warning must be either 0 or 1')
        let canonic_dst = split(records[2], ';', 1)
        let test_dst = rainbow_csv#preserving_quoted_split(escaped_entry, ',')[0]
        if !canonic_warning
            call AssertEqual(len(canonic_dst), len(test_dst))
            call AssertEqual(join(test_dst, ','), escaped_entry)
            let unescaped_dst = rainbow_csv#unescape_quoted_fields(test_dst)
            call AssertEqual(join(unescaped_dst, ';'), records[2])
        endif
    endfor
endfunc
