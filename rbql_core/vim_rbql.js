const os = require('os');
const path = require('path');
const fs = require('fs');

const rbql_csv = require('./rbql-js/rbql_csv.js');


function exception_to_error_info(e) {
    let exceptions_type_map = {
        'RbqlRuntimeError': 'query execution',
        'RbqlParsingError': 'query parsing',
        'RbqlIOHandlingError': 'IO handling'
    };
    let error_type = 'unexpected';
    if (e.constructor && e.constructor.name && exceptions_type_map.hasOwnProperty(e.constructor.name)) {
        error_type = exceptions_type_map[e.constructor.name];
    }
    let error_msg = e.hasOwnProperty('message') ? e.message : String(e);
    return [error_type, error_msg];
}


function handle_worker_success(warnings, output_path) {
    console.log('OK');
    console.log(output_path);
    if (warnings !== null) {
        for (let i = 0; i < warnings.length; i++) {
            console.log(warnings[i]);
        }
    }
}


function handle_worker_error(exception) {
    let [error_type, error_msg] = exception_to_error_info(exception);
    console.log(error_type);
    let result_file_path = '';
    console.log(result_file_path); 
    console.log(error_msg);
    process.exit(0);
}




function main() {
    let cmd_args = process.argv;
    cmd_args = cmd_args.slice(2);
    let [input_path, query_file, encoding, delim, policy, comment_prefix, output_delim, output_policy, with_headers_raw, trim_spaces_raw] = cmd_args;
    let init_source_file = null;
    let query = fs.readFileSync(query_file, 'utf-8');
    var tmp_dir = os.tmpdir();
    let output_path = path.join(tmp_dir, path.basename(input_path) + '.txt');
    let warnings = [];
    let with_headers = {'True': true, 'False': false}[with_headers_raw];
    let trim_spaces = {'True': true, 'False': false}[trim_spaces_raw];
    let options = {'trim_whitespaces': trim_spaces};
    rbql_csv.query_csv(query, input_path, delim, policy, output_path, output_delim, output_policy, encoding, warnings, with_headers, comment_prefix, /*user_init_code=*/'', options).then(() => handle_worker_success(warnings, output_path)).catch(e => handle_worker_error(e));
}


main();
