let field_regular_expression = '"((?:[^"]*"")*[^"]*)"';
let field_rgx = new RegExp('^' + field_regular_expression);
let field_rgx_external_whitespaces = new RegExp('^ *' + field_regular_expression + ' *');


// TODO consider making this file (and rbql.js) both node and browser compatible: https://caolan.org/posts/writing_for_node_and_the_browser.html


function split_lines(text) {
    return text.split(/\r\n|\r|\n/);
}


function extract_next_field(src, dlm, preserve_quotes_and_whitespaces, allow_external_whitespaces, cidx, result) {
    var warning = false;
    let src_cur = src.substring(cidx);
    let rgx = allow_external_whitespaces ? field_rgx_external_whitespaces : field_rgx;
    let match_obj = rgx.exec(src_cur);
    if (match_obj !== null) {
        let match_end = match_obj[0].length;
        if (cidx + match_end == src.length || src[cidx + match_end] == dlm) {
            if (preserve_quotes_and_whitespaces) {
                result.push(match_obj[0]);
            } else {
                result.push(match_obj[1].replace(/""/g, '"'));
            }
            return [cidx + match_end + 1, false];
        }
        warning = true;
    }
    var uidx = src.indexOf(dlm, cidx);
    if (uidx == -1)
        uidx = src.length;
    var field = src.substring(cidx, uidx);
    warning = warning || field.indexOf('"') != -1;
    result.push(field);
    return [uidx + 1, warning];
}


function split_quoted_str(src, dlm, preserve_quotes_and_whitespaces=false) {
    // This function is newline-agnostic i.e. it can also split records with multiline fields.
    if (src.indexOf('"') == -1) // Optimization for most common case
        return [src.split(dlm), false];
    var result = [];
    var cidx = 0;
    var warning = false;
    let allow_external_whitespaces = dlm != ' ';
    while (cidx < src.length) {
        var extraction_report = extract_next_field(src, dlm, preserve_quotes_and_whitespaces, allow_external_whitespaces, cidx, result);
        cidx = extraction_report[0];
        warning = warning || extraction_report[1];
    }
    if (src.charAt(src.length - 1) == dlm)
        result.push('');
    return [result, warning];
}


function quote_field(src, delim) {
    if (src.indexOf(delim) != -1 || src.indexOf('"') != -1) {
        var escaped = src.replace(/"/g, '""');
        return `"${escaped}"`;
    }
    return src;
}


function rfc_quote_field(src, delim) {
    if (src.indexOf(delim) != -1 || src.indexOf('"') != -1 || src.indexOf('\n') != -1 || src.indexOf('\r') != -1) {
        var escaped = src.replace(/"/g, '""');
        return `"${escaped}"`;
    }
    return src;
}


function unquote_field(field) {
    let rgx = new RegExp('^' + ' *' + field_regular_expression + ' *$');
    let match_obj = rgx.exec(field);
    if (match_obj !== null) {
        return match_obj[1].replace(/""/g, '"');
    }
    return field;
}


function unquote_fields(fields) {
    return fields.map(unquote_field);
}


function split_whitespace_separated_str(src, preserve_whitespaces=false) {
    var rgxp = preserve_whitespaces ? new RegExp(' *[^ ]+ *', 'g') : new RegExp('[^ ]+', 'g');
    let result = [];
    let match_obj = null;
    while((match_obj = rgxp.exec(src)) !== null) {
        result.push(match_obj[0]);
    }
    if (preserve_whitespaces) {
        for (let i = 0; i < result.length - 1; i++) {
            result[i] = result[i].slice(0, -1);
        }
    }
    return result;
}


function smart_split(src, dlm, policy, preserve_quotes_and_whitespaces) {
    if (policy === 'simple')
        return [src.split(dlm), false];
    if (policy === 'whitespace')
        return [split_whitespace_separated_str(src, preserve_quotes_and_whitespaces), false];
    if (policy === 'monocolumn')
        return [[src], false];
    return split_quoted_str(src, dlm, preserve_quotes_and_whitespaces);
}


class MultilineRecordAggregator {
    constructor(comment_prefix, comment_regex) {
        this.comment_prefix = comment_prefix;
        this.comment_regex = comment_regex;
        this.reset();
    }
    add_line(line_text) {
        if (this.has_full_record || this.has_comment_line) {
            throw new Error('Invalid usage - record aggregator must be reset before adding new lines');
        }
        if (this.comment_prefix && this.rfc_line_buffer.length == 0 && line_text.startsWith(this.comment_prefix)) {
            this.has_comment_line = true;
            return false;
        }
        if (this.comment_regex && this.rfc_line_buffer.length == 0 && line_text.search(this.comment_regex) != -1) {
            this.has_comment_line = true;
            return false;
        }
        let match_list = line_text.match(/"/g);
        let has_unbalanced_double_quote = match_list && match_list.length % 2 == 1;
        this.rfc_line_buffer.push(line_text);
        this.has_full_record = (!has_unbalanced_double_quote && this.rfc_line_buffer.length == 1) || (has_unbalanced_double_quote && this.rfc_line_buffer.length > 1);
        return this.has_full_record;
    }
    is_inside_multiline_record() {
        return this.rfc_line_buffer.length && !this.has_full_record;
    }
    get_full_line(line_separator) {
        return this.rfc_line_buffer.join(line_separator);
    }
    get_num_lines_in_record() {
        return this.rfc_line_buffer.length;
    }
    reset() {
        this.rfc_line_buffer = [];
        this.has_full_record = false;
        this.has_comment_line = false;
    }
}


module.exports.split_quoted_str = split_quoted_str;
module.exports.split_whitespace_separated_str = split_whitespace_separated_str;
module.exports.smart_split = smart_split;
module.exports.quote_field = quote_field;
module.exports.rfc_quote_field = rfc_quote_field;
module.exports.unquote_field = unquote_field;
module.exports.unquote_fields = unquote_fields;
module.exports.split_lines = split_lines;
module.exports.MultilineRecordAggregator = MultilineRecordAggregator;
