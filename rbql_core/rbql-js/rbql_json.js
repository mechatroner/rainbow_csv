const fs = require('fs');
const os = require('os');
const path = require('path');
const util = require('util');

const rbql = require('./rbql.js');
const csv_utils = require('./csv_utils.js');
const json_utils = require('./json_utils.js');

class RbqlIOHandlingError extends Error {}


// FIXME add bash-level unit tests for the cli tool that would use json format.
// FIXME merge all iterators into a single one and all writers into one.

function assert(condition, message=null) {
    if (!condition) {
        if (!message) {
            message = 'Assertion error';
        }
        throw new AssertionError(message);
    }
}


function deduplicate_header_keys(header) {
    // This algorithm is O(N^2) but we don't expect to have a lot of keys.
    let unique_keys = [];
    let deduplicated_keys = new Set();
    for (let h of header) {
        let unique_key = h;
        let dedup_counter = 1;
        while (unique_keys.indexOf(unique_key) != -1) {
            dedup_counter += 1;
            unique_key = `${h}_${dedup_counter}`;
        }
        unique_keys.push(unique_key);
        if (dedup_counter != 1)
            deduplicated_keys.add(h);
    }
    return [unique_keys, Array.from(deduplicated_keys).sort()];
}


function get_json_object_to_write(header, fields) {
    if (fields.length == 1)
        return fields[0];
    if (header.length && fields.length != header.length)
        throw new RbqlIOHandlingError(`Inconsistent number of columns in output header and the current record: ${header.length} != ${fields.length}`);
    let result = {};
    for (let i = 0; i < fields.length; i++) {
        let key_name = i < header.length ? header[i] : `col_${i + 1}`;
        result[key_name] = fields[i];
    }
    return result;
}


function stringify_json_line_python_style(obj) {
    // The default JSON.stringify() unfortunatelly doesn't produce pretty json lines like in json lines examples here: https://jsonlines.org/examples/
    // Python by default stringifies with extra readability whitespaces e.g. `{'foo':1,'bar':2}` becomes `{"foo": 1, "bar": 2}`.
    // The third `spaces` arg in `JSON.stringify` makes it pretty print the whole thing with newlines, so we post-format it via this hack.
    return JSON.stringify(obj, null, 1).replace(/^ +/gm, "").replace(/,\n/g, ", \n").replace(/\n/g, "");
}


class JsonArrayObjectWriter extends rbql.RBQLOutputWriter {
    //FIXME add unit tests
    constructor(stream, close_stream_on_finish, encoding='utf-8', line_separator='\n', pretty_indent=null, wrap_in_json_array=true) {
        super();
        this.stream = stream;
        this.encoding = encoding;
        if (encoding)
            this.stream.setDefaultEncoding(encoding);
        this.stream.on('error', (error_obj) => { this.store_first_error(error_obj); })
        this.line_separator = line_separator;

        this.close_stream_on_finish = close_stream_on_finish;

        this.header = [];
        this.deduplicated_keys = [];
        this.first_error = null;
        this.num_records_written = 0;
        this.pretty_indent = pretty_indent;
        this.wrap_in_json_array = wrap_in_json_array;
    }

    store_first_error(error_obj) {
        // Store only first error because it is typically more important than the subsequent ones.
        if (this.first_error === null)
            this.first_error = error_obj;
    }

    set_header(header) {
        if (header !== null) {
            [this.header, this.deduplicated_keys] = deduplicate_header_keys(header);
        }
    }

    async finish() {
        if (this.wrap_in_json_array) {
            if (this.num_records_written == 0) {
                // Output an empty array if no entries were produced.
                this.stream.write('[');
            }
            this.stream.write(this.line_separator);
            this.stream.write(']');
            this.stream.write(this.line_separator); // POSIX requires a newline at the end of text files.
        } else {
            if (this.num_records_written > 0) {
                this.stream.write(this.line_separator); // POSIX requires a newline at the end of text files.
            }
        }
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
        if (this.deduplicated_keys.length > 0) {
            let keys_to_report = this.deduplicated_keys.map(key => `"${key}"`).join(', ');
            result.push(`Deduplicated output json keys to avoid data loss: ${keys_to_report}`);
        }
        return result;
    };

    async do_write(object_to_write) {
        if (this.num_records_written == 0) {
            if (this.wrap_in_json_array) {
                this.stream.write('[');
                this.stream.write(this.line_separator);
            }
        } else {
            this.stream.write(',');
            this.stream.write(this.line_separator);
        }
        // FIXME add unit tests for pretty mode
        // FIXME add integration test for pretty mode, both js and python
        if (this.pretty_indent === null) {
            this.stream.write(stringify_json_line_python_style(object_to_write));
        } else {
            this.stream.write(JSON.stringify(object_to_write, null, this.pretty_indent));
        }
        this.num_records_written += 1;
        let writer_error = this.first_error;
        return new Promise(function(resolve, reject) {
            if (writer_error !== null) {
                reject(writer_error);
            } else {
                resolve();
            }
        });
    }

    async write(fields) {
        let object_to_write = get_json_object_to_write(this.header, fields);
        await this.do_write(object_to_write);
        // The return value is needed for the stacked writers architecture in rbql.js.
        // So far the only writer that can return `false` is the TopWriter which uses it as a flag to request stop when the limit is reached.
        // This writer always succeeds (unless there is an exception).
        return true;
    };
}

class JsonLinesWriter extends rbql.RBQLOutputWriter {
    constructor(stream, close_stream_on_finish, encoding='utf-8', line_separator='\n') {
        super();
        this.stream = stream;
        this.encoding = encoding;
        if (encoding)
            this.stream.setDefaultEncoding(encoding);
        this.stream.on('error', (error_obj) => { this.store_first_error(error_obj); })
        this.line_separator = line_separator;

        this.close_stream_on_finish = close_stream_on_finish;

        this.header = [];
        this.deduplicated_keys = [];
        this.first_error = null;
    }

    store_first_error(error_obj) {
        // Store only first error because it is typically more important than the subsequent ones.
        if (this.first_error === null)
            this.first_error = error_obj;
    }

    set_header(header) {
        if (header !== null) {
            [this.header, this.deduplicated_keys] = deduplicate_header_keys(header);
        }
    }

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
        if (this.deduplicated_keys.length > 0) {
            let keys_to_report = this.deduplicated_keys.map(key => `"${key}"`).join(', ');
            result.push(`Deduplicated output json keys to avoid data loss: ${keys_to_report}`);
        }
        return result;
    };


    async do_write(object_to_write) {
        this.stream.write(stringify_json_line_python_style(object_to_write));
        this.stream.write(this.line_separator);
        let writer_error = this.first_error;
        return new Promise(function(resolve, reject) {
            if (writer_error !== null) {
                reject(writer_error);
            } else {
                resolve();
            }
        });
    }


    async write(fields) {
        let object_to_write = get_json_object_to_write(this.header, fields);
        await this.do_write(object_to_write);
        // The return value is needed for the stacked writers architecture in rbql.js.
        // So far the only writer that can return `false` is the TopWriter which uses it as a flag to request stop when the limit is reached.
        // This writer always succeeds (unless there is an exception).
        return true;
    };
}


class JsonArrayObjectRecordIterator extends rbql.RBQLInputIterator {
    // TODO we can optimize this to process objects as they arrive if we have implementation for json-batches parser.
    // Json array would be almost similar format except that we have array object at root which can be easily skipped.
    // Another difference between this format and json batches would be commas at the end of each object but they can also be easily skipped.
    constructor(stream, encoding='utf-8', table_name='input', variable_prefix='a') {
        super();
        this.stream = stream;
        this.encoding = encoding;
        this.table_name = table_name;
        this.variable_prefix = variable_prefix;


        this.decoder = null;
        if (encoding == 'utf-8') {
            // This was copied from the csv impl, see comments there.
            this.decoder = new util.TextDecoder(encoding, {fatal: true, stream: true});
        }

        this.input_exhausted = false;
        this.started = false;

        // Holds an external "resolve" function which is called when everything is fine.
        this.resolve_current_record = null;
        // Holds an external "reject" function which is called when error has occured.
        this.reject_current_record = null;
        // Holds last exception if we don't have any reject callbacks from clients yet.
        this.current_exception = null;

        this.produced_records_queue = new csv_utils.RecordQueue();
        this.record_number = 0;
        this.input_data_chunks = [];
    }

    get_header() {
        // Returning "a1" as a column name actually has a side effect because it would try to initialize a.a1 and a['a1'] values in rbql engine.
        return [this.variable_prefix];
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


    try_resolve_next_record() {
        this.try_propagate_exception();
        if (this.resolve_current_record === null)
            return;

        let record = this.produced_records_queue.dequeue();
        if (record === null && !this.input_exhausted)
            return;
        let resolve = this.resolve_current_record;
        this.reset_external_callbacks();
        this.record_number += 1;
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
        this.input_data_chunks.push(decoded_string);
    };


    process_data_stream_end() {
        this.input_exhausted = true;
        let input_data_string = this.input_data_chunks.join('');
        let json_object = null;
        try {
            json_object = JSON.parse(input_data_string);
        } catch (e) {
            if (e instanceof SyntaxError) {
                this.store_or_propagate_exception(new RbqlIOHandlingError(`Unable to parse input stream as JSON: ${e.message}`));
            } else {
                this.store_or_propagate_exception(e);
            }
            return;
        }
        if (!Array.isArray(json_object)) {
            this.store_or_propagate_exception(new RbqlIOHandlingError("Input JSON root node must be array in array iteration mode"));
            return;
        }
        for (let record of json_object) {
            this.produced_records_queue.enqueue([record]);
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
        this.stream.on('data', (data_chunk) => { this.process_data_stream_chunk(data_chunk); });
        this.stream.on('end', () => { this.process_data_stream_end(); });
    };
}


class JsonLinesRecordIterator extends rbql.RBQLInputIterator {
    // TODO add query modifier with "noheaders" this would name keys as `a1`, `a2`, etc.
    // FIXME add unit tests
    constructor(stream, encoding='utf-8', table_name='input', variable_prefix='a') {
        super();
        this.stream = stream;
        this.encoding = encoding;
        this.table_name = table_name;
        this.variable_prefix = variable_prefix;


        this.decoder = null;
        if (encoding == 'utf-8') {
            // This was copied from the csv impl, see comments there.
            this.decoder = new util.TextDecoder(encoding, {fatal: true, stream: true});
        }

        this.input_exhausted = false;
        this.started = false;

        this.record_number = 0;
        this.line_number = 0;

        this.partially_decoded_line = '';
        this.partially_decoded_line_ends_with_cr = false;

        // Holds an external "resolve" function which is called when everything is fine.
        this.resolve_current_record = null;
        // Holds an external "reject" function which is called when error has occured.
        this.reject_current_record = null;
        // Holds last exception if we don't have any reject callbacks from clients yet.
        this.current_exception = null;

        this.produced_records_queue = new csv_utils.RecordQueue();
    }

    get_header() {
        // Returning "a1" as a column name actually has a side effect because it would try to initialize a.a1 and a['a1'] values in rbql engine.
        return [this.variable_prefix];
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


    try_resolve_next_record() {
        this.try_propagate_exception();
        if (this.resolve_current_record === null)
            return;

        let record = this.produced_records_queue.dequeue();
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


    process_record_line(line) {
        this.record_number += 1;
        try {
            this.produced_records_queue.enqueue([JSON.parse(line)]);
        } catch (e) {
            if (e instanceof SyntaxError) {
                this.store_or_propagate_exception(new RbqlIOHandlingError(`Error in line: ${this.line_number} Unable to parse "${line} as JSON: ${e.message}"`));
            } else {
                this.store_or_propagate_exception(e);
            }
            return;
        }
        this.try_resolve_next_record();
    };


    process_line(line) {
        this.line_number += 1;
        this.process_record_line(line);
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


    process_data_stream_end() {
        this.input_exhausted = true;
        if (this.partially_decoded_line.length) {
            let last_line = this.partially_decoded_line;
            this.partially_decoded_line = '';
            this.process_line(last_line);
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
        this.stream.on('data', (data_chunk) => { this.process_data_stream_chunk(data_chunk); });
        this.stream.on('end', () => { this.process_data_stream_end(); });
    };
}


class JsonStreamRecordIterator extends rbql.RBQLInputIterator {
    // TODO add query modifier with "noheaders" this would name keys as `a1`, `a2`, etc.
    // FIXME add unit tests
    constructor(stream, encoding='utf-8', table_name='input', variable_prefix='a') {
        super();
        this.stream = stream;
        this.encoding = encoding;
        this.table_name = table_name;
        this.variable_prefix = variable_prefix;


        this.decoder = null;
        if (encoding == 'utf-8') {
            // This was copied from the csv impl, see comments there.
            this.decoder = new util.TextDecoder(encoding, {fatal: true, stream: true});
        }

        this.input_exhausted = false;
        this.started = false;

        this.record_number = 0;
        this.line_number = 0;

        this.partially_decoded_line = '';
        this.partially_decoded_line_ends_with_cr = false;

        // Holds an external "resolve" function which is called when everything is fine.
        this.resolve_current_record = null;
        // Holds an external "reject" function which is called when error has occured.
        this.reject_current_record = null;
        // Holds last exception if we don't have any reject callbacks from clients yet.
        this.current_exception = null;

        this.json_finalizer = new json_utils.JsonFinalizer();
        this.produced_records_queue = new csv_utils.RecordQueue();
    }

    get_header() {
        // Returning "a1" as a column name actually has a side effect because it would try to initialize a.a1 and a['a1'] values in rbql engine.
        return [this.variable_prefix];
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


    try_resolve_next_record() {
        this.try_propagate_exception();
        if (this.resolve_current_record === null)
            return;

        let record = this.produced_records_queue.dequeue();
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
        this.json_finalizer.add_data(decoded_string);
        while (true) {
            let object_text = null;
            try {
                object_text = this.json_finalizer.get_first_object();
            } catch (e) {
                this.store_or_propagate_exception(new RbqlIOHandlingError(`Unable to interpret data as JSON (record number ${this.record_number}): ${e.message}"`));
            }
            if (object_text === null) {
                // This means that there is no completed objects in the finalizer.
                break;
            }
            this.json_finalizer.erase_first_object();
            try {
                this.produced_records_queue.enqueue([JSON.parse(object_text)]);
                this.record_number += 1;
            } catch (e) {
                if (e instanceof SyntaxError) {
                    // FIXME ut this
                    this.store_or_propagate_exception(new RbqlIOHandlingError(`Unable to parse data as JSON (record number ${this.record_number}): ${e.message}"`));
                } else {
                    this.store_or_propagate_exception(e);
                }
                return;
            }
            this.try_resolve_next_record();
        }
    };


    process_data_stream_end() {
        this.input_exhausted = true;
        if (!this.json_finalizer.is_empty()) {
            this.store_or_propagate_exception(new RbqlIOHandlingError(`Trailing data in ${this.table_name} stream that can't be parsed as JSON objects`));
        }
        // This last call is needed so that null is dequeued from the queue which initiaties the query completion.
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
        this.stream.on('data', (data_chunk) => { this.process_data_stream_chunk(data_chunk); });
        this.stream.on('end', () => { this.process_data_stream_end(); });
    };
}

async function query_json(query_text, input_path, output_path, output_warnings, user_init_code='', input_json_lines=true, output_json_lines=true, pretty_indent=null, input_json_stream=false, output_json_stream=false) {
    let input_stream = input_path === null ? process.stdin : fs.createReadStream(input_path);
    let [output_stream, close_output_on_finish] = output_path === null ? [process.stdout, false] : [fs.createWriteStream(output_path), true];

    let default_init_source_path = path.join(os.homedir(), '.rbql_init_source.js');
    if (user_init_code == '' && fs.existsSync(default_init_source_path)) {
        user_init_code = read_user_init_code(default_init_source_path);
    }
    let input_file_dir = input_path ? path.dirname(input_path) : null;
    let join_tables_registry = null;

    let input_iterator = null;
    if (input_json_lines) {
        input_iterator = new JsonLinesRecordIterator(input_stream);
    } else if (input_json_stream) {
        input_iterator = new JsonStreamRecordIterator(input_stream);
    } else {
        input_iterator = new JsonArrayObjectRecordIterator(input_stream);
    }

    let output_writer = null;
    if (output_json_lines) {
        output_writer = new JsonLinesWriter(output_stream, close_output_on_finish);
    } else if (output_json_stream) {
        output_writer = new JsonArrayObjectWriter(output_stream, close_output_on_finish, 'utf-8', '\n', pretty_indent, /*wrap_in_json_array=*/false);
    } else {
        output_writer = new JsonArrayObjectWriter(output_stream, close_output_on_finish, 'utf-8', '\n', pretty_indent);
    }

    await rbql.query(query_text, input_iterator, output_writer, output_warnings, join_tables_registry, user_init_code);
}


module.exports.deduplicate_header_keys = deduplicate_header_keys;
module.exports.stringify_json_line_python_style = stringify_json_line_python_style;
module.exports.get_json_object_to_write = get_json_object_to_write;
module.exports.JsonLinesWriter = JsonLinesWriter;
module.exports.JsonArrayObjectWriter = JsonArrayObjectWriter;
module.exports.JsonLinesRecordIterator = JsonLinesRecordIterator;
module.exports.JsonStreamRecordIterator = JsonStreamRecordIterator;
module.exports.query_json = query_json;
