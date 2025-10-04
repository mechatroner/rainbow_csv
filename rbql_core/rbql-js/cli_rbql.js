#!/usr/bin/env node

const fs = require('fs');
const readline = require('readline');

const rbql = require('./rbql.js');
const rbql_csv = require('./rbql_csv.js');
const csv_utils = require('./csv_utils.js');
const cli_parser = require('./cli_parser.js');

let out_format_names = ['csv', 'tsv', 'monocolumn', 'input'];

var error_format = 'hr';
var interactive_mode = false;


// TODO implement colored output like in Python version
// TODO implement query history like in Python version. "readline" modules allows to do that, see "completer" parameter.
// TODO switch to built-in node util parseArgs module (added in 2022)

// FIXME test readline on Win: disable interactive mode?

// FIXME handle broken pipe error and add tests. See Python version.


class RbqlParsingError extends Error {}
class GenericError extends Error {}


function show_error_plain_text(error_type, error_msg) {
    if (interactive_mode) {
        console.log(`\x1b[31;1mError [${error_type}]:\x1b[0m ${error_msg}`);
    } else {
        console.error(`Error [${error_type}]: ${error_msg}`);
    }
}


function report_error_json(error_type, error_msg) {
    let report = new Object();
    report.error_type = error_type;
    report.error = error_msg;
    process.stderr.write(JSON.stringify(report));
}


function show_exception(e) {
    let [error_type, error_msg] = rbql.exception_to_error_info(e);
    if (error_format == 'hr') {
        show_error_plain_text(error_type, error_msg);
    } else {
        report_error_json(error_type, error_msg);
    }
}


function show_warning(msg) {
    if (interactive_mode) {
        console.log('\x1b[33;1mWarning:\x1b[0m ' + msg);
    } else {
        console.error('Warning: ' + msg);
    }
}


function normalize_delim(delim) {
    if (delim == 'TAB')
        return '\t';
    if (delim == '\\t')
        return '\t';
    return delim;
}


function get_default(src, key, default_val) {
    return src.hasOwnProperty(key) ? src[key] : default_val;
}


async function read_user_query(user_input_reader) {
    let finish_promise = new Promise(function(resolve, reject) {
        user_input_reader.question('Input SQL-like RBQL query and press Enter:\n> ', (query) => {
            resolve(query);
        });
    });
    let query = await finish_promise;
    return query;
}


function get_default_policy(delim) {
    if ([';', ','].indexOf(delim) != -1) {
        return 'quoted';
    } else if (delim == ' ') {
        return 'whitespace';
    } else {
        return 'simple';
    }
}


function is_delimited_table(sampled_lines, delim, policy) {
    if (sampled_lines.length < 10)
        return false;
    let num_fields = null;
    for (var i = 0; i < sampled_lines.length; i++) {
        let [fields, warning] = csv_utils.smart_split(sampled_lines[i], delim, policy, true);
        if (warning)
            return false;
        if (num_fields === null)
            num_fields = fields.length;
        if (num_fields < 2 || num_fields != fields.length)
            return false;
    }
    return true;
}


async function sample_lines(table_path) {
    let finish_promise = new Promise(function(resolve, reject) {
        let input_reader = readline.createInterface({ input: fs.createReadStream(table_path) });
        let sampled_lines = [];
        input_reader.on('line', line => {
            if (sampled_lines.length < 10) {
                sampled_lines.push(line);
            } else {
                input_reader.close();
            }
        });
        input_reader.on('close', () => { resolve(sampled_lines); });
    });
    let sampled_lines = await finish_promise;
    return sampled_lines;
}


async function sample_records(table_path, encoding, delim, policy, comment_prefix, trim_whitespaces, comment_regex) {
    let table_stream = fs.createReadStream(table_path);
    let sampling_iterator = new rbql_csv.CSVRecordIterator(table_stream, null, encoding, delim, policy, /*has_header=*/false, comment_prefix, 'input', 'a', trim_whitespaces, comment_regex);
    let sampled_records = await sampling_iterator.get_all_records(10);
    let warnings = sampling_iterator.get_warnings();
    return [sampled_records, warnings];
}


async function autodetect_delim_policy(table_path) {
    let sampled_lines = await sample_lines(table_path);
    let autodetection_dialects = [['\t', 'simple'], [',', 'quoted'], [';', 'quoted'], ['|', 'simple']];
    for (var i = 0; i < autodetection_dialects.length; i++) {
        let [delim, policy] = autodetection_dialects[i];
        if (is_delimited_table(sampled_lines, delim, policy))
            return [delim, policy];
    }
    if (table_path.endsWith('.csv'))
        return [',', 'quoted'];
    if (table_path.endsWith('.tsv'))
        return ['\t', 'simple'];
    return [null, null];
}


function print_colorized(records, delim, show_column_names, with_headers) {
    let reset_color_code = '\x1b[0m';
    let color_codes = ['\x1b[0m', '\x1b[31m', '\x1b[32m', '\x1b[33m', '\x1b[34m', '\x1b[35m', '\x1b[36m', '\x1b[31;1m', '\x1b[32;1m', '\x1b[33;1m'];
    for (let r = 0; r < records.length; r++) {
        let out_fields = [];
        for (let c = 0; c < records[r].length; c++) {
            let color_code = color_codes[c % color_codes.length];
            let field = records[r][c];
            let colored_field = (!show_column_names || (with_headers && r == 0)) ? color_code + field : `${color_code}a${c + 1}:${field}`;
            out_fields.push(colored_field);
        }
        let out_line = out_fields.join(delim) + reset_color_code;
        console.log(out_line);
    }
}


async function handle_query_success(warnings, output_path, encoding, delim, policy) {
    if (error_format == 'hr') {
        if (warnings !== null) {
            for (let i = 0; i < warnings.length; i++) {
                show_warning(warnings[i]);
            }
        }
        if (interactive_mode) {
            let [records, _warnings] = await sample_records(output_path, encoding, delim, policy, /*comment_prefix=*/null, /*trim_whitespaces=*/false, /*comment_regex=*/null);
            console.log('\nOutput table preview:');
            console.log('====================================');
            print_colorized(records, delim, false, false);
            console.log('====================================');
            console.log('Success! Result table was saved to: ' + output_path);
        }
    } else {
        if (warnings !== null && warnings.length) {
            var warnings_report = JSON.stringify({'warnings': warnings});
            process.stderr.write(warnings_report);
        }
    }
}


async function run_with_js(args) {
    var delim = normalize_delim(args['delim']);
    var policy = args['policy'] ? args['policy'] : get_default_policy(delim);
    var query = args['query'];
    if (!query)
        throw new RbqlParsingError('RBQL query is empty');
    var input_path = get_default(args, 'input', null);
    var output_path = get_default(args, 'output', null);
    var csv_encoding = args['encoding'];
    var with_headers = args['with-headers'];
    var comment_prefix = args['comment-prefix'];
    var comment_regex = args['comment-regex'];
    var trim_whitespaces = args['trim-spaces'];
    var output_delim = get_default(args, 'out-delim', null);
    var output_policy = get_default(args, 'out-policy', null);
    let init_source_file = get_default(args, 'init-source-file', null);
    let output_format = args['out-format'];
    if (output_delim === null) {
        [output_delim, output_policy] = output_format == 'input' ? [delim, policy] : rbql_csv.interpret_named_csv_format(output_format);
    }

    let user_init_code = '';
    if (init_source_file !== null)
        user_init_code = rbql_csv.read_user_init_code(init_source_file);
    try {
        let warnings = [];
        // Do not use bulk_read mode here because:
        // * Bulk read can't handle large file since node unable to read the whole file into a string, see https://github.com/mechatroner/rainbow_csv/issues/19
        // * In case of stdin read we would have to use the util.TextDecoder anyway
        // * binary/latin-1 do not require the decoder anyway
        // * This is CLI so no way we are in the Electron environment which can't use the TextDecoder
        // * Streaming mode works a little faster (since we don't need to do the manual validation)
        // TODO check if the current node installation doesn't have ICU enabled (which is typicaly provided by Node.js by default, see https://nodejs.org/api/intl.html) and report a user-friendly error with an option to use latin-1 encoding or switch the interpreter
        await rbql_csv.query_csv(query, input_path, delim, policy, output_path, output_delim, output_policy, csv_encoding, warnings, with_headers, comment_prefix, user_init_code, {'trim_whitespaces': trim_whitespaces, 'comment_regex': comment_regex});
        await handle_query_success(warnings, output_path, csv_encoding, output_delim, output_policy);
        return true;
    } catch (e) {
        if (!interactive_mode)
            throw e;
        show_exception(e);
        return false;
    }
}


function get_default_output_path(input_path, delim) {
    let well_known_extensions = {',': '.csv', '\t': '.tsv'};
    if (well_known_extensions.hasOwnProperty(delim))
        return input_path + well_known_extensions[delim];
    return input_path + '.txt';
}


async function show_preview(input_path, encoding, delim, policy, with_headers, comment_prefix, trim_whitespaces, comment_regex) {
    let [records, warnings] = await sample_records(input_path, encoding, delim, policy, comment_prefix, trim_whitespaces, comment_regex);
    console.log('Input table preview:');
    console.log('====================================');
    print_colorized(records, delim, true, with_headers);
    console.log('====================================\n');
    for (let warning of warnings) {
        show_warning(warning);
    }
}


async function run_interactive_loop(args) {
    let input_path = get_default(args, 'input', null);
    if (!input_path)
        throw new GenericError('Input file must be provided in interactive mode. You can use stdin input only in non-interactive mode');
    if (error_format != 'hr')
        throw new GenericError('Only default "hr" error format is supported in interactive mode');


    let delim = get_default(args, 'delim', null);
    let policy = null;
    if (delim !== null) {
        delim = normalize_delim(delim);
        policy = args['policy'] ? args['policy'] : get_default_policy(delim);
    } else {
        [delim, policy] = await autodetect_delim_policy(input_path);
        if (!delim)
            throw new GenericError('Unable to autodetect table delimiter. Provide column separator explicitly with "--delim" option');
    }
    await show_preview(input_path, args['encoding'], delim, policy, args['with-headers'], args['comment-prefix'], args['trim-spaces'], args['comment-regex']);
    args.delim = delim;
    args.policy = policy;
    if (!args.output) {
        args.output = get_default_output_path(input_path, delim);
        show_warning('Output path was not provided. Result set will be saved as: ' + args.output);
    }

    let user_input_reader = readline.createInterface({ input: process.stdin, output: process.stdout });
    try {
        while (true) {
            let query = await read_user_query(user_input_reader);
            args.query = query;
            let success = await run_with_js(args);
            if (success)
                break;
        }
    } finally {
        user_input_reader.close();
    }
}


let tool_description = `rbql-js

Run RBQL queries against CSV files and data streams

rbql-js supports two modes: non-interactive (with "--query" option) and interactive (without "--query" option)
Interactive mode shows source table preview which makes query editing much easier. Usage example:
  $ rbql-js --input input.csv
Non-interactive mode supports source tables in stdin. Usage example:
  $ rbql-js --query "select a1, a2 order by a1" --delim , < input.csv
`;

let epilog = `
Description of the available CSV split policies:
  * "simple" - RBQL uses simple split() function and doesn't perform special handling of double quote characters
  * "quoted" - Separator can be escaped inside double-quoted fields. Double quotes inside double-quoted fields must be doubled
  * "quoted_rfc" - Same as "quoted", but also allows newlines inside double-quoted fields, see RFC-4180: https://tools.ietf.org/html/rfc4180
  * "whitespace" - Works only with whitespace separator, multiple consecutive whitespaces are treated as a single whitespace
  * "monocolumn" - RBQL doesn't perform any split at all, each line is a single-element record, i.e. only "a1" and "NR" are available
`;


async function do_main(args) {

    if (args['version']) {
        console.log(rbql.version);
        process.exit(0);
    }

    if (args.hasOwnProperty('policy') && args['policy'] === 'monocolumn')
        args['delim'] = '';

    if (args.hasOwnProperty('policy') && !args.hasOwnProperty('delim'))
        throw new GenericError('Using "--policy" without "--delim" is not allowed');

    if (args.encoding == 'latin-1')
        args.encoding = 'binary';

    error_format = args['error-format'];

    if (args.hasOwnProperty('query')) {
        interactive_mode = false;
        if (!args.hasOwnProperty('delim')) {
            throw new GenericError('Separator must be provided with "--delim" option in non-interactive mode');
        }
        await run_with_js(args);
    } else {
        interactive_mode = true;
        if (error_format == 'json') {
            throw new GenericError('json error format is not compatible with interactive mode');
        }
        await run_interactive_loop(args);
    }
}


function main() {
    var scheme = {
        '--input': {'help': 'Read csv table from FILE instead of stdin. Required in interactive mode', 'metavar': 'FILE'},
        '--query': {'help': 'Query string in rbql. Run in interactive mode if empty', 'metavar': 'QUERY'},
        '--output': {'help': 'Write output table to FILE instead of stdout', 'metavar': 'FILE'},
        '--delim': {'help': 'Delimiter character or multicharacter string, e.g. "," or "###". Can be autodetected in interactive mode', 'metavar': 'DELIM'},
        '--policy': {'help': 'Split policy, see the explanation below. Supported values: "simple", "quoted", "quoted_rfc", "whitespace", "monocolumn". Can be autodetected in interactive mode', 'metavar': 'POLICY'},
        '--with-headers': {'boolean': true, 'help': 'Indicates that input (and join) table has header'},
        '--comment-prefix': {'help': 'Ignore lines in input and join tables that start with the comment PREFIX, e.g. "#"', 'metavar': 'PREFIX'},
        '--comment-regex': {'help': 'Ignore lines in input and join tables that contain the comment REGEX.', 'metavar': 'REGEX'},
        '--encoding': {'default': 'utf-8', 'help': 'Manually set csv encoding', 'metavar': 'ENCODING'},
        '--trim-spaces': {'boolean': true, 'help': 'Trim leading and trailing spaces from fields'},
        '--out-format': {'default': 'input', 'help': 'Output format. Supported values: ' + out_format_names.map(v => `"${v}"`).join(', '), 'metavar': 'FORMAT'},
        '--out-delim': {'help': 'Output delim. Use with "out-policy". Overrides out-format', 'metavar': 'DELIM'},
        '--out-policy': {'help': 'Output policy. Use with "out-delim". Overrides out-format', 'metavar': 'POLICY'},
        '--error-format': {'default': 'hr', 'help': 'Errors and warnings format. [hr|json]', 'hidden': true},
        '--version': {'boolean': true, 'help': 'Print RBQL version and exit'},
        '--init-source-file': {'help': 'Path to init source file to use instead of ~/.rbql_init_source.js', 'hidden': true}
    };
    let args = cli_parser.parse_cmd_args(process.argv, scheme, tool_description, epilog);
    do_main(args).then(() => {}).catch(error_info => { show_exception(error_info); process.exit(1); });
}


if (require.main === module) {
    main();
}


