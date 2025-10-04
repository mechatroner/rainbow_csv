const fs = require('fs');
const os = require('os');
const path = require('path');
const util = require('util');

const rbql = require('./rbql.js');
const csv_utils = require('./csv_utils.js');


const utf_decoding_error = 'Unable to decode input table as UTF-8. Use binary (latin-1) encoding instead';


class RbqlIOHandlingError extends Error {}
class AssertionError extends Error {}


// TODO performance improvement: replace smart_split() with polymorphic_split()


function assert(condition, message=null) {
    if (!condition) {
        if (!message) {
            message = 'Assertion error';
        }
        throw new AssertionError(message);
    }
}


function interpret_named_csv_format(format_name) {
    format_name = format_name.toLowerCase();
    if (format_name == 'monocolumn')
        return ['', 'monocolumn'];
    if (format_name == 'csv')
        return [',', 'quoted'];
    if (format_name == 'tsv')
        return ['\t', 'simple'];
    throw new RbqlIOHandlingError(`Unknown format name: "${format_name}"`);
}



function is_ascii(str) {
    return /^[\x00-\x7F]*$/.test(str);
}


function read_user_init_code(rbql_init_source_path) {
    return fs.readFileSync(rbql_init_source_path, 'utf-8');
}


function remove_utf8_bom(line, assumed_source_encoding) {
    if (assumed_source_encoding == 'binary' && line.length >= 3 && line.charCodeAt(0) === 0xEF && line.charCodeAt(1) === 0xBB && line.charCodeAt(2) === 0xBF) {
        return line.substring(3);
    }
    if (assumed_source_encoding == 'utf-8' && line.length >= 1 && line.charCodeAt(0) === 0xFEFF) {
        return line.substring(1);
    }
    return line;
}


function make_inconsistent_num_fields_warning(table_name, inconsistent_records_info) {
    let [record_num_1, num_fields_1, record_num_2, num_fields_2] = rbql.sample_first_two_inconsistent_records(inconsistent_records_info);
    let warn_msg = `Number of fields in "${table_name}" table is not consistent: `;
    warn_msg += `e.g. record ${record_num_1} -> ${num_fields_1} fields, record ${record_num_2} -> ${num_fields_2} fields`;
    return warn_msg;
}


function expanduser(filepath) {
    if (filepath.charAt(0) === '~') {
        return path.join(os.homedir(), filepath.slice(1));
    }
    return filepath;
}


function try_read_index(index_path) {
    var content = null;
    try {
        content = fs.readFileSync(index_path, 'utf-8');
    } catch (e) {
        return [];
    }
    var lines = content.split('\n');
    var records = [];
    for (var i = 0; i < lines.length; i++) {
        if (!lines[i])
            continue;
        var record = lines[i].split('\t');
        records.push(record);
    }
    return records;
}


function get_index_record(index_path, key) {
    var records = try_read_index(index_path);
    for (var i = 0; i < records.length; i++) {
        if (records[i].length && records[i][0] == key) {
            return records[i];
        }
    }
    return null;
}


function find_table_path(main_table_dir, table_id) {
    // If table_id is a relative path it could be relative either to the current directory or to the main table dir.
    var candidate_path = expanduser(table_id);
    if (fs.existsSync(candidate_path)) {
        return candidate_path;
    }
    if (main_table_dir && !path.isAbsolute(candidate_path)) {
        candidate_path = path.join(main_table_dir, candidate_path);
        if (fs.existsSync(candidate_path)) {
            return candidate_path;
        }
    }
    let table_names_settings_path = path.join(os.homedir(), '.rbql_table_names');
    var name_record = get_index_record(table_names_settings_path, table_id);
    if (name_record && name_record.length > 1 && fs.existsSync(name_record[1])) {
        return name_record[1];
    }
    return null;
}


class RecordQueue {
    // TODO compare performance with a linked list
    constructor() {
        this.push_stack = [];
        this.pull_stack = [];
    }

    enqueue(record) {
        this.push_stack.push(record);
    }

    dequeue() {
        if (!this.pull_stack.length) {
            if (!this.push_stack.length)
                return null;
            this.pull_stack = this.push_stack;
            this.pull_stack.reverse();
            this.push_stack = [];
        }
        return this.pull_stack.pop();
    }
}


class CSVRecordIterator extends rbql.RBQLInputIterator {
    // CSVRecordIterator implements a typical async producer-consumer model with an internal buffer:
    // get_record() - consumer
    // stream.on('data') - producer
    constructor(stream, csv_path, encoding, delim, policy, has_header=false, comment_prefix=null, table_name='input', variable_prefix='a', trim_whitespaces=false, comment_regex=null) {
        super();
        this.stream = stream;
        this.csv_path = csv_path;
        assert((this.stream === null) != (this.csv_path === null));
        this.encoding = encoding;
        this.delim = delim;
        this.policy = policy;

        this.has_header = has_header;
        this.first_record = null;
        this.first_record_should_be_emitted = !has_header;
        this.header_preread_complete = false;

        this.table_name = table_name;
        this.variable_prefix = variable_prefix;
        this.comment_prefix = comment_prefix;
        this.comment_regex = comment_regex;
        this.trim_whitespaces = trim_whitespaces;

        this.decoder = null;
        if (encoding == 'utf-8' && this.csv_path === null) {
            // Unfortunately util.TextDecoder has serious flaws:
            // 1. It doesn't work in Node without ICU: https://nodejs.org/api/util.html#util_new_textdecoder_encoding_options
            // 2. It is broken in Electron: https://github.com/electron/electron/issues/18733

            // Technically we can implement our own custom streaming text decoder, using the 3 following technologies:
            // 1. decode-encode validation method from https://stackoverflow.com/a/32279283/2898283
            // 2. Scanning buffer chunks for non-continuation utf-8 bytes from the end of the buffer:
            //    src_buffer -> (buffer_before, buffer_after) where buffer_after is very small(a couple of bytes) and buffer_before is large and ends with a non-continuation bytes
            // 3. Internal buffer to store small tail part from the previous buffer
            this.decoder = new util.TextDecoder(encoding, {fatal: true, stream: true});
        }

        this.input_exhausted = false;
        this.started = false;

        this.utf8_bom_removed = false; // BOM doesn't get automatically removed by the decoder when utf-8 file is treated as latin-1
        this.first_defective_line = null;

        this.fields_info = new Map();
        this.NR = 0; // Record number
        this.NL = 0; // Line number (NL != NR when the CSV file has comments or multiline fields)

        this.line_aggregator = new csv_utils.MultilineRecordAggregator(comment_prefix, comment_regex);

        this.partially_decoded_line = '';
        this.partially_decoded_line_ends_with_cr = false;

        // Holds an external "resolve" function which is called when everything is fine.
        this.resolve_current_record = null;
        // Holds an external "reject" function which is called when error has occured.
        this.reject_current_record = null;
        // Holds last exception if we don't have any reject callbacks from clients yet.
        this.current_exception = null;

        this.produced_records_queue = new RecordQueue();

        this.process_line_polymorphic = policy == 'quoted_rfc' ? this.process_partial_rfc_record_line : this.process_record_line_simple;
    }


    handle_query_modifier(modifier) {
        // For `... WITH (header) ...` syntax
        if (['header', 'headers'].indexOf(modifier) != -1) {
            this.has_header = true;
            this.first_record_should_be_emitted = false;
        }
        if (['noheader', 'noheaders'].indexOf(modifier) != -1) {
            this.has_header = false;
            this.first_record_should_be_emitted = true;
        }
    }


    reset_external_callbacks() {
        // Drop external callbacks simultaneously since promises can only resolve once, see: https://stackoverflow.com/a/18218542/2898283
        this.reject_current_record = null;
        this.resolve_current_record = null;
    }

    try_propagate_exception() {
        if (this.current_exception && this.reject_current_record) {
            let reject = this.reject_current_record;
            let exception = this.current_exception;
            this.reset_external_callbacks();
            this.current_exception = null;
            reject(exception);
        }
    }


    store_or_propagate_exception(exception) {
        if (this.current_exception === null)
            // Ignore subsequent exceptions if we already have an unreported error. This way we prioritize earlier errors over the more recent ones.
            this.current_exception = exception;
        this.try_propagate_exception();
    }


    async preread_first_record() {
        if (this.header_preread_complete)
            return;
        this.first_record = await this.get_record();
        this.header_preread_complete = true; // We must set header_preread_complete to true after calling get_record(), because get_record() uses it internally.
        if (this.first_record === null) {
            return;
        }
        if (this.stream)
            this.stream.pause();
        this.first_record = this.first_record.slice();
    };


    async get_variables_map(query_text) {
        let variable_map = new Object();
        rbql.parse_basic_variables(query_text, this.variable_prefix, variable_map);
        rbql.parse_array_variables(query_text, this.variable_prefix, variable_map);

        await this.preread_first_record();
        if (this.has_header && this.first_record) {
            rbql.parse_attribute_variables(query_text, this.variable_prefix, this.first_record, 'CSV header line', variable_map);
            rbql.parse_dictionary_variables(query_text, this.variable_prefix, this.first_record, variable_map);
        }
        return variable_map;
    };

    async get_header() {
        await this.preread_first_record();
        return this.has_header ? this.first_record : null;
    }


    try_resolve_next_record() {
        this.try_propagate_exception();
        if (this.resolve_current_record === null)
            return;

        let record = null;
        if (this.first_record_should_be_emitted && this.header_preread_complete) {
            this.first_record_should_be_emitted = false;
            record = this.first_record;
        } else {
            record = this.produced_records_queue.dequeue();
        }

        if (record === null && !this.input_exhausted)
            return;
        let resolve = this.resolve_current_record;
        this.reset_external_callbacks();
        resolve(record);
    };


    async get_record() {
        if (!this.started)
            await this.start();
        if (this.stream && this.stream.isPaused())
            this.stream.resume();

        let parent_iterator = this;
        let current_record_promise = new Promise(function(resolve, reject) {
            parent_iterator.resolve_current_record = resolve;
            parent_iterator.reject_current_record = reject;
        });
        this.try_resolve_next_record();
        return current_record_promise;
    };


    async get_all_records(num_records=null) {
        let records = [];
        while (true) {
            let record = await this.get_record();
            if (record === null)
                break;
            records.push(record);
            if (num_records && records.length >= num_records) {
                this.stop();
                break;
            }
        }
        return records;
    };


    process_record_line_simple(line) {
        if (this.comment_prefix && line.startsWith(this.comment_prefix))
            return; // Just skip the line
        if (this.comment_regex && line.search(this.comment_regex) != -1)
            return; // Just skip the line
        this.process_record_line(line);
    }


    process_record_line(line) {
        this.NR += 1;
        var [record, warning] = csv_utils.smart_split(line, this.delim, this.policy, false);
        if (this.trim_whitespaces) {
            record = record.map((v) => v.trim());
        }
        if (warning) {
            if (this.first_defective_line === null) {
                this.first_defective_line = this.NL;
                if (this.policy == 'quoted_rfc')
                    this.store_or_propagate_exception(new RbqlIOHandlingError(`Inconsistent double quote escaping in ${this.table_name} table at record ${this.NR}, line ${this.NL}`));
            }
        }
        let num_fields = record.length;
        if (!this.fields_info.has(num_fields))
            this.fields_info.set(num_fields, this.NR);
        this.produced_records_queue.enqueue(record);
        this.try_resolve_next_record();
    };


    process_partial_rfc_record_line(line) {
        this.line_aggregator.add_line(line);
        if (this.line_aggregator.has_comment_line) {
            this.line_aggregator.reset();
        } else if (this.line_aggregator.has_full_record) {
            this.process_record_line(this.line_aggregator.get_full_line('\n'));
            this.line_aggregator.reset();
        }
    };


    process_line(line) {
        this.NL += 1;
        if (this.NL === 1) {
            var clean_line = remove_utf8_bom(line, this.encoding);
            if (clean_line != line) {
                line = clean_line;
                this.utf8_bom_removed = true;
            }
        }
        this.process_line_polymorphic(line);
    };


    process_data_stream_chunk(data_chunk) {
        let decoded_string = null;
        if (this.decoder) {
            try {
                decoded_string = this.decoder.decode(data_chunk);
            } catch (e) {
                if (e instanceof TypeError) {
                    this.store_or_propagate_exception(new RbqlIOHandlingError(utf_decoding_error));
                } else {
                    this.store_or_propagate_exception(e);
                }
                return;
            }
        } else {
            decoded_string = data_chunk.toString(this.encoding);
        }
        let line_starts_with_lf = decoded_string.length && decoded_string[0] == '\n';
        let first_line_index = line_starts_with_lf && this.partially_decoded_line_ends_with_cr ? 1 : 0;
        this.partially_decoded_line_ends_with_cr = decoded_string.length && decoded_string[decoded_string.length - 1] == '\r';
        let lines = csv_utils.split_lines(decoded_string);
        lines[0] = this.partially_decoded_line + lines[0];
        assert(first_line_index == 0 || lines[0].length == 0);
        this.partially_decoded_line = lines.pop();
        for (let i = first_line_index; i < lines.length; i++) {
            this.process_line(lines[i]);
        }
    };


    process_data_bulk(data_blob) {
        let decoded_string = data_blob.toString(this.encoding);
        if (this.encoding == 'utf-8') {
            // Using hacky comparison method from here: https://stackoverflow.com/a/32279283/2898283
            // TODO get rid of this once TextDecoder is really fixed or when alternative method of reliable decoding appears
            let control_buffer = Buffer.from(decoded_string, 'utf-8');
            if (Buffer.compare(data_blob, control_buffer) != 0) {
                this.store_or_propagate_exception(new RbqlIOHandlingError(utf_decoding_error));
                return;
            }
        }
        let lines = csv_utils.split_lines(decoded_string);
        if (lines.length && lines[lines.length - 1].length == 0)
            lines.pop();
        for (let i = 0; i < lines.length; i++) {
            this.process_line(lines[i]);
        }
        if (this.line_aggregator.is_inside_multiline_record()) {
            this.process_record_line(this.line_aggregator.get_full_line('\n'));
        }
        this.input_exhausted = true;
        this.try_resolve_next_record(); // Should be a NOOP here?
    }


    process_data_stream_end() {
        this.input_exhausted = true;
        if (this.partially_decoded_line.length) {
            let last_line = this.partially_decoded_line;
            this.partially_decoded_line = '';
            this.process_line(last_line);
        }
        if (this.line_aggregator.is_inside_multiline_record()) {
            this.process_record_line(this.line_aggregator.get_full_line('\n'));
        }
        this.try_resolve_next_record();
    };


    stop() {
        if (this.stream)
            this.stream.destroy(); // TODO consider using pause() instead
    };


    async start() {
        if (this.started)
            return;
        this.started = true;
        if (this.stream) {
            this.stream.on('data', (data_chunk) => { this.process_data_stream_chunk(data_chunk); });
            this.stream.on('end', () => { this.process_data_stream_end(); });
        } else {
            let parent_iterator = this;
            return new Promise(function(resolve, reject) {
                fs.readFile(parent_iterator.csv_path, (err, data_blob) => {
                    if (err) {
                        reject(err);
                    } else {
                        parent_iterator.process_data_bulk(data_blob);
                        resolve();
                    }
                });
            });
        }
    };


    get_warnings() {
        let result = [];
        if (this.first_defective_line !== null)
            result.push(`Inconsistent double quote escaping in ${this.table_name} table. E.g. at line ${this.first_defective_line}`);
        if (this.utf8_bom_removed)
            result.push(`UTF-8 Byte Order Mark (BOM) was found and skipped in ${this.table_name} table`);
        if (this.fields_info.size > 1)
            result.push(make_inconsistent_num_fields_warning(this.table_name, this.fields_info));
        return result;
    };
}


class CSVWriter extends rbql.RBQLOutputWriter {
    constructor(stream, close_stream_on_finish, encoding, delim, policy, line_separator='\n') {
        super();
        this.stream = stream;
        this.encoding = encoding;
        if (encoding)
            this.stream.setDefaultEncoding(encoding);
        this.stream.on('error', (error_obj) => { this.store_first_error(error_obj); })
        this.delim = delim;
        this.policy = policy;
        this.line_separator = line_separator;
        this.sub_array_delim = delim == '|' ? ';' : '|';

        this.close_stream_on_finish = close_stream_on_finish;

        this.null_in_output = false;
        this.delim_in_simple_output = false;
        this.header_len = null;
        this.first_error = null;

        if (policy == 'simple') {
            this.polymorphic_join = this.simple_join;
        } else if (policy == 'quoted') {
            this.polymorphic_join = this.quoted_join;
        } else if (policy == 'quoted_rfc') {
            this.polymorphic_join = this.quoted_join_rfc;
        } else if (policy == 'monocolumn') {
            this.polymorphic_join = this.mono_join;
        } else if (policy == 'whitespace') {
            this.polymorphic_join = this.simple_join;
        } else {
            throw new RbqlIOHandlingError('Unknown output csv policy');
        }
    }


    store_first_error(error_obj) {
        // Store only first error because it is typically more important than the subsequent ones.
        if (this.first_error === null)
            this.first_error = error_obj;
    }

    set_header(header) {
        if (header !== null) {
            this.header_len = header.length;
            this.write(header);
        }
    }


    quoted_join(fields) {
        let delim = this.delim;
        var quoted_fields = fields.map(function(v) { return csv_utils.quote_field(String(v), delim); });
        return quoted_fields.join(this.delim);
    };


    quoted_join_rfc(fields) {
        let delim = this.delim;
        var quoted_fields = fields.map(function(v) { return csv_utils.rfc_quote_field(String(v), delim); });
        return quoted_fields.join(this.delim);
    };


    mono_join(fields) {
        if (fields.length > 1) {
            throw new RbqlIOHandlingError('Unable to use "Monocolumn" output format: some records have more than one field');
        }
        return fields[0];
    };


    simple_join(fields) {
        var res = fields.join(this.delim);
        if (fields.join('').indexOf(this.delim) != -1) {
            this.delim_in_simple_output = true;
        }
        return res;
    };


    normalize_fields(out_fields) {
        for (var i = 0; i < out_fields.length; i++) {
            if (out_fields[i] == null) {
                this.null_in_output = true;
                out_fields[i] = '';
            } else if (Array.isArray(out_fields[i])) {
                this.normalize_fields(out_fields[i]);
                out_fields[i] = out_fields[i].join(this.sub_array_delim);
            }
        }
    };


    async write(fields) {
        if (this.header_len !== null && fields.length != this.header_len)
            throw new RbqlIOHandlingError(`Inconsistent number of columns in output header and the current record: ${this.header_len} != ${fields.length}`);
        this.normalize_fields(fields);
        this.stream.write(this.polymorphic_join(fields));
        this.stream.write(this.line_separator);
        let writer_error = this.first_error;
        return new Promise(function(resolve, reject) {
            if (writer_error !== null) {
                reject(writer_error);
            } else {
                resolve(true);
            }
        });
    };


    _write_all(table) {
        for (let i = 0; i < table.length; i++) {
            this.write(table[i]);
        }
    };


    async finish() {
        let close_stream_on_finish = this.close_stream_on_finish;
        let output_stream = this.stream;
        let output_encoding = this.encoding;
        let writer_error = this.first_error;
        let finish_promise = new Promise(function(resolve, reject) {
            if (writer_error !== null) {
                reject(writer_error);
            }
            if (close_stream_on_finish) {
                output_stream.end('', output_encoding, () => { resolve(); });
            } else {
                setTimeout(() => { resolve(); }, 0);
            }
        });
        return finish_promise;
    };


    get_warnings() {
        let result = [];
        if (this.null_in_output)
            result.push('null values in output were replaced by empty strings');
        if (this.delim_in_simple_output)
            result.push('Some output fields contain separator');
        return result;
    };

}


class FileSystemCSVRegistry extends rbql.RBQLTableRegistry {
    constructor(input_file_dir, delim, policy, encoding, has_header=false, comment_prefix=null, options=null) {
        super();
        this.input_file_dir = input_file_dir;
        this.delim = delim;
        this.policy = policy;
        this.encoding = encoding;
        this.has_header = has_header;
        this.comment_prefix = comment_prefix;
        this.stream = null;
        this.record_iterator = null;

        this.options = options;
        this.bulk_input_path = null;
        this.table_path = null;
    }

    get_iterator_by_table_id(table_id) {
        this.table_path = find_table_path(this.input_file_dir, table_id);
        if (this.table_path === null) {
            throw new RbqlIOHandlingError(`Unable to find join table "${table_id}"`);
        }
        if (this.options && this.options['bulk_read']) {
            this.bulk_input_path = this.table_path;
        } else {
            this.stream = fs.createReadStream(this.table_path);
        }
        let trim_whitespaces = this.options && this.options['trim_whitespaces'] ? true : false;
        let comment_regex = this.options && this.options.hasOwnProperty('comment_regex') ? this.options['comment_regex'] : null;
        this.record_iterator = new CSVRecordIterator(this.stream, this.bulk_input_path, this.encoding, this.delim, this.policy, this.has_header, this.comment_prefix, table_id, 'b', trim_whitespaces, comment_regex);
        return this.record_iterator;
    };

    get_warnings(output_warnings) {
        if (this.record_iterator && this.has_header) {
            output_warnings.push(`The first record in JOIN file ${path.basename(this.table_path)} was also treated as header (and skipped)`);
        }
    }
}


async function query_csv(query_text, input_path, input_delim, input_policy, output_path, output_delim, output_policy, csv_encoding, output_warnings, with_headers=false, comment_prefix=null, user_init_code='', options=null) {
    let input_stream = null;
    let bulk_input_path = null;
    if (options && options['bulk_read'] && input_path) {
        bulk_input_path = input_path;
    } else {
        input_stream = input_path === null ? process.stdin : fs.createReadStream(input_path);
    }
    let trim_whitespaces = options && options['trim_whitespaces'] ? true : false;
    let comment_regex = options && options.hasOwnProperty('comment_regex') ? options['comment_regex'] : null;
    let [output_stream, close_output_on_finish] = output_path === null ? [process.stdout, false] : [fs.createWriteStream(output_path), true];
    if (input_delim == '"' && input_policy == 'quoted')
        throw new RbqlIOHandlingError('Double quote delimiter is incompatible with "quoted" policy');
    if (csv_encoding == 'latin-1')
        csv_encoding = 'binary';
    if (!is_ascii(query_text) && csv_encoding == 'binary')
        throw new RbqlIOHandlingError('To use non-ascii characters in query enable UTF-8 encoding instead of latin-1/binary');
    if ((!is_ascii(input_delim) || !is_ascii(output_delim)) && csv_encoding == 'binary')
        throw new RbqlIOHandlingError('To use non-ascii characters in query enable UTF-8 encoding instead of latin-1/binary');

    let default_init_source_path = path.join(os.homedir(), '.rbql_init_source.js');
    if (user_init_code == '' && fs.existsSync(default_init_source_path)) {
        user_init_code = read_user_init_code(default_init_source_path);
    }
    let input_file_dir = input_path ? path.dirname(input_path) : null;
    let join_tables_registry = new FileSystemCSVRegistry(input_file_dir, input_delim, input_policy, csv_encoding, with_headers, comment_prefix, options);
    let input_iterator = new CSVRecordIterator(input_stream, bulk_input_path, csv_encoding, input_delim, input_policy, with_headers, comment_prefix, 'input', 'a', trim_whitespaces, comment_regex);
    let output_writer = new CSVWriter(output_stream, close_output_on_finish, csv_encoding, output_delim, output_policy);

    await rbql.query(query_text, input_iterator, output_writer, output_warnings, join_tables_registry, user_init_code);
    join_tables_registry.get_warnings(output_warnings);
}


module.exports.is_ascii = is_ascii;
module.exports.CSVRecordIterator = CSVRecordIterator;
module.exports.CSVWriter = CSVWriter;
module.exports.FileSystemCSVRegistry = FileSystemCSVRegistry;
module.exports.interpret_named_csv_format = interpret_named_csv_format;
module.exports.read_user_init_code = read_user_init_code;
module.exports.query_csv = query_csv;
module.exports.RecordQueue = RecordQueue;
module.exports.exception_to_error_info = rbql.exception_to_error_info;
