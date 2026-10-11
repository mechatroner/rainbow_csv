import json
import sys
import os
import io
import re

from . import rbql_engine
from . import csv_utils
from . import rbql_csv

debug_mode = False

def set_debug_mode():
    global debug_mode
    debug_mode = True

# FIXME merge all iterators into a single one (use pre-parsing approach from js impl) and all writers into one.


def get_json_object_to_write(header, fields):
    if len(fields) == 1:
        return fields[0]
    if len(header) and len(fields) != len(header):
        raise rbql_engine.RbqlIOHandlingError('Inconsistent number of columns in output header and the current record: {} != {}'.format(len(header), len(fields)))
    result = dict()
    for i in range(len(fields)):
        key_name = header[i] if i < len(header) else 'col{}'.format(i + 1)
        result[key_name] = fields[i]
    return result


def finalize_stream(stream, close_stream_on_finish):
    if close_stream_on_finish:
        stream.close()
        return
    try:
        stream.flush()
    except BrokenPipeError as exc:
        try:
            sys.stdout.close()
        except Exception:
            pass


def deduplicate_header_keys(header):
    # This algorithm is O(N^2) but we don't expect to have a lot of keys.
    unique_keys = list()
    deduplicated_keys = set()
    for h in header:
        unique_key = h
        dedup_counter = 1
        while unique_key in unique_keys:
            dedup_counter += 1
            unique_key = '{}_{}'.format(h, dedup_counter)
        unique_keys.append(unique_key)
        if dedup_counter != 1:
            deduplicated_keys.add(h)
    return (unique_keys, sorted(list(deduplicated_keys)))


class JsonLinesWriter(rbql_engine.RBQLOutputWriter):
    def __init__(self, stream, close_stream_on_finish, encoding, line_separator='\n'):
        assert encoding in ['utf-8', 'latin-1', None]
        self.stream = rbql_csv.encode_output_stream(stream, encoding)
        self.line_separator = line_separator
        self.close_stream_on_finish = close_stream_on_finish
        self.broken_pipe = False
        self.header = []
        self.deduplicated_keys = []

    def write(self, fields):
        object_to_write = get_json_object_to_write(self.header, fields)
        try:
            json_str = json.dumps(object_to_write, ensure_ascii=False, default=str)
        except TypeError as e:
            raise rbql_engine.RbqlIOHandlingError('Error serializing object to JSON: {}'.format(e))

        try:
            self.stream.write(json_str)
            self.stream.write(self.line_separator)
            return True
        except BrokenPipeError as exc:
            self.broken_pipe = True
            return False

    def finish(self):
        if not self.broken_pipe:
            finalize_stream(self.stream, self.close_stream_on_finish)

    def set_header(self, header):
        if header is not None:
            # Json objects don't allow duplicate keys so we have to dedup them to make sure they are unique to avoid accidental data loss.
            self.header, self.deduplicated_keys = deduplicate_header_keys(header)

    def get_warnings(self):
        warnings = []
        if len(self.deduplicated_keys) != 0:
            sorted_keys = sorted(['"{}"'.format(v) for v in self.deduplicated_keys])
            warnings.append('Deduplicated output json keys to avoid data loss: {}'.format(', '.join(sorted_keys)))
        return warnings


class JsonArrayObjectRecordIterator(rbql_engine.RBQLInputIterator):
    # TODO add query modifier with "noheaders" this would name keys as `a1`, `a2`, etc.
    def __init__(self, stream, encoding, table_name='input', variable_prefix='a'):
        assert encoding in ['utf-8', 'latin-1', None]
        self.encoding = encoding
        self.stream = rbql_csv.encode_input_stream(stream, encoding)
        self.table_name = table_name
        self.variable_prefix = variable_prefix
        try:
            self.json_object = json.load(self.stream)
        except json.JSONDecodeError as e:
            raise rbql_engine.RbqlIOHandlingError('Unable to parse input as JSON: {}'.format(e))
        if not isinstance(self.json_object, list):
            raise rbql_engine.RbqlIOHandlingError('Input JSON root node must be array in array iteration mode')
        self.record_number = 0
        self.line_number = 1 # The object has to start at the first line so we just keep NL at 1.

    def get_header(self):
        # FIXME consider if this is a hack or not. Test queries with stars like `SELECT a.*, a.*` or `SELECT *`.
        # We might not need this (i.e. we can have it return None as the default impl) if we support the write_header flag, see the rbql_engine.py comments.
        # Returning "a1" as a column name actually has a side effect because it would try to initialize a.a1 and a['a1'] values in rbql engine.
        return [self.variable_prefix]

    def get_record(self):
        if self.record_number >= len(self.json_object):
            return None
        self.record_number += 1
        return [self.json_object[self.record_number - 1]]


class JsonArrayObjectWriter(rbql_engine.RBQLOutputWriter):
    # By setting `wrap_in_json_array` to false (and pretty_indent) we get json-stream writer
    def __init__(self, stream, close_stream_on_finish, encoding, line_separator='\n', pretty_indent=None, wrap_in_json_array=True):
        assert encoding in ['utf-8', 'latin-1', None]
        self.stream = rbql_csv.encode_output_stream(stream, encoding)
        self.line_separator = line_separator
        self.close_stream_on_finish = close_stream_on_finish
        self.broken_pipe = False
        self.pretty_indent=pretty_indent
        self.num_records_written = 0
        self.header = []
        self.deduplicated_keys = []
        self.wrap_in_json_array = wrap_in_json_array

    def write(self, fields):
        object_to_write = get_json_object_to_write(self.header, fields)
        try:
            # Intentionally do not split json_str to add extra pretty indents because the root level is a flat array and shifting everything right just reduces density for the sake of dubious consistency. 
            json_str = json.dumps(object_to_write, ensure_ascii=False, default=str, indent=self.pretty_indent)
        except TypeError as e:
            raise rbql_engine.RbqlIOHandlingError('Error serializing object to JSON: {}'.format(e))

        try:
            if self.num_records_written == 0:
                if self.wrap_in_json_array:
                    self.stream.write('[')
                    self.stream.write(self.line_separator)
            else:
                self.stream.write(',')
                self.stream.write(self.line_separator)
            self.stream.write(json_str)
            self.num_records_written += 1
            return True
        except BrokenPipeError as exc:
            self.broken_pipe = True
            return False

    def finish(self):
        if self.broken_pipe:
            return
        if self.wrap_in_json_array:
            if self.num_records_written == 0:
                # Output an empty array if no entries were produced.
                self.stream.write('[')
            self.stream.write(self.line_separator)
            self.stream.write(']')
            self.stream.write(self.line_separator) # POSIX requires a newline at the end of text files.
        else:
            if self.num_records_written > 0:
                self.stream.write(self.line_separator) # POSIX requires a newline at the end of text files.
        finalize_stream(self.stream, self.close_stream_on_finish)

    def set_header(self, header):
        if header is None:
            return
        # Json objects don't allow duplicate keys so we have to dedup them to make sure they are unique to avoid accidental data loss.
        self.header, self.deduplicated_keys = deduplicate_header_keys(header)

    def get_warnings(self):
        warnings = []
        if len(self.deduplicated_keys) != 0:
            sorted_keys = sorted(['"{}"'.format(v) for v in self.deduplicated_keys])
            warnings.append('Deduplicated output json keys to avoid data loss: {}'.format(', '.join(sorted_keys)))
        return warnings


# NOTE: using json lines format as input is essentially equivalent to `select json.loads(a1) | select a1['name']` type of query.
class JsonLinesRecordIterator(rbql_engine.RBQLInputIterator):
    def __init__(self, stream, encoding, table_name='input', variable_prefix='a', chunk_size=1024):
        assert encoding in ['utf-8', 'latin-1', None]
        self.encoding = encoding
        self.stream = rbql_csv.encode_input_stream(stream, encoding)
        self.table_name = table_name
        self.variable_prefix = variable_prefix

        self.buffer = ''
        self.exhausted = False
        self.record_number = 0
        self.line_number = 0
        self.chunk_size = chunk_size

    def get_header(self):
        # Returning "a1" as a column name actually has a side effect because it would try to initialize a.a1 and a['a1'] values in rbql engine.
        return [self.variable_prefix]

    def _get_row_from_buffer(self):
        str_before, separator, str_after = csv_utils.extract_line_from_data(self.buffer)
        if separator is None:
            return None
        if separator == '\r' and str_after == '':
            one_more = self.stream.read(1)
            if one_more == '\n':
                separator = '\r\n'
            else:
                str_after = one_more
        self.buffer = str_after
        return str_before

    def _read_until_found(self):
        if self.exhausted:
            return
        chunks = []
        while True:
            chunk = self.stream.read(self.chunk_size)
            if not chunk:
                self.exhausted = True
                break
            chunks.append(chunk)
            if csv_utils.newline_rgx.search(chunk) is not None:
                break
        self.buffer += ''.join(chunks)

    def get_row(self):
        try:
            row = self._get_row_from_buffer()
            if row is None:
                self._read_until_found()
                row = self._get_row_from_buffer()
                if row is None:
                    assert self.exhausted
                    if not len(self.buffer):
                        return None
                    row = self.buffer
                    self.buffer = ''
            self.line_number += 1
            # Don't try to handle BOM here because is should be very rare for json files and it is fine to fail
            return row
        except UnicodeDecodeError:
            raise rbql_engine.RbqlIOHandlingError('Unable to decode input table as UTF-8. Use binary (latin-1) encoding instead')

    def get_record(self):
        while True:
            line = self.get_row()
            if line is None:
                return None
            line = line.strip()
            if not line:
                continue
            try:
                json_obj = json.loads(line)
                self.record_number += 1
                return [json_obj]
            except json.JSONDecodeError as e:
                raise rbql_engine.RbqlIOHandlingError('Error decoding JSON in {} table at record {}, line {}: {}'.format(self.table_name, self.record_number + 1, self.line_number, str(e)))


class JsonStreamRecordIterator(rbql_engine.RBQLInputIterator):
    def __init__(self, stream, encoding, table_name='input', variable_prefix='a', chunk_size=16384):
        assert encoding in ['utf-8', 'latin-1', None]
        self.encoding = encoding
        self.stream = rbql_csv.encode_input_stream(stream, encoding)
        self.table_name = table_name
        self.variable_prefix = variable_prefix
        self.decoder = json.JSONDecoder()

        self.buffer = ''
        self.exhausted = False
        self.chunk_size = chunk_size
        self.num_chunks_read_internal_stat = 0 # This is for unit tests only
        self.record_number = 0

    def get_header(self):
        # Returning "a1" as a column name actually has a side effect because it would try to initialize a.a1 and a['a1'] values in rbql engine.
        return [self.variable_prefix]

    def get_record(self):
        if self.exhausted:
            return None
        while True:
            try:
                # Strip whitespaces because `raw_decode` fails when there are leading whitespaces/newlines and it doens't consume trailing spaces.
                self.buffer = self.buffer.lstrip()
                entry, index_after = self.decoder.raw_decode(self.buffer)
                self.record_number += 1
                self.buffer = self.buffer[index_after:]
                return [entry]
            except json.JSONDecodeError:
                # TODO consider adopting JS approach with the ad-hoc finalizer parser to be able to abort processing in the middle once we have encountered a bad prefix.
                # Currently we go until the very end which is not at all fast-fail, especially even when the file is not even json streams.
                pass
            chunk = self.stream.read(self.chunk_size)
            self.num_chunks_read_internal_stat += 1
            if not chunk:
                self.exhausted = True
                if len(self.buffer):
                    raise rbql_engine.RbqlIOHandlingError('Unable to parse data as json stream - failed around record {}'.format(self.record_number))
                return None
            self.buffer += chunk



# TODO we might want the output to optionally be CSV too. 
def query_json(query_text, input_path, output_path, output_warnings, user_init_code='', input_json_lines=True, output_json_lines=True, pretty_indent=None, input_json_stream=False, output_json_stream=False):
    output_stream, close_output_on_finish = (None, False)
    input_stream, close_input_on_finish = (None, False)
    join_tables_registry = None
    try:
        output_stream, close_output_on_finish = (sys.stdout, False) if output_path is None else (open(output_path, 'wb'), True)
        input_stream, close_input_on_finish = (sys.stdin, False) if input_path is None else (open(input_path, 'rb'), True)

        default_init_source_path = os.path.join(os.path.expanduser('~'), '.rbql_init_source.py')
        if user_init_code == '' and os.path.exists(default_init_source_path):
            user_init_code = rbql_csv.read_user_init_code(default_init_source_path)

        input_iterator = None
        if input_json_lines:
            input_iterator = JsonLinesRecordIterator(input_stream, 'utf-8', table_name='input', variable_prefix='a')
        elif input_json_stream:
            input_iterator = JsonStreamRecordIterator(input_stream, 'utf-8', table_name='input', variable_prefix='a')
        else:
            input_iterator = JsonArrayObjectRecordIterator(input_stream, 'utf-8', table_name='input', variable_prefix='a')

        output_writer = None
        if output_json_lines:
            output_writer = JsonLinesWriter(output_stream, close_output_on_finish, 'utf-8')
        elif output_json_stream:
            output_writer = JsonArrayObjectWriter(output_stream, close_output_on_finish, 'utf-8', pretty_indent=pretty_indent, wrap_in_json_array=False)
        else:
            output_writer = JsonArrayObjectWriter(output_stream, close_output_on_finish, 'utf-8', pretty_indent=pretty_indent)

        if debug_mode:
            rbql_engine.set_debug_mode()
        rbql_engine.query(query_text, input_iterator, output_writer, output_warnings, join_tables_registry, user_init_code)
    finally:
        if close_input_on_finish:
            input_stream.close()
        if close_output_on_finish:
            output_stream.close()

