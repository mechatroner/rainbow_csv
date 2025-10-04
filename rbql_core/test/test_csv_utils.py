#!/usr/bin/env python

import sys
import os
import argparse
import random
import unittest
import re
import tempfile
import time
import importlib
import codecs
import io
import subprocess
import json
import shutil
import copy

script_dir = os.path.dirname(os.path.abspath(__file__))
# Use insert instead of append to make sure that we are using local rbql here.
sys.path.insert(0, os.path.join(os.path.dirname(script_dir), 'rbql-py'))

import rbql
from rbql import rbql_csv
from rbql import csv_utils
from rbql import rbql_engine


########################################################################################################
# Below are some generic functions
########################################################################################################


line_separators = ['\n', '\r\n', '\r']


vinf = rbql_engine.VariableInfo


python_minor_version = int(sys.version_info[1])


def normalize_warnings(warnings):
    # TODO can we get rid of this function? Why do we need to normalize warnings?
    # TODO move into a common test lib module e.g. "tests_common.py"
    result = []
    for warning in warnings:
        if warning.find('Number of fields in "input" table is not consistent') != -1:
            result.append('inconsistent input records')
        elif warning.find('Inconsistent double quote escaping') != -1:
            result.append('inconsistent double quote escaping')
        elif warning.find('None values in output were replaced by empty strings') != -1:
            result.append('null values in output were replaced')
        elif warning == 'UTF-8 Byte Order Mark (BOM) was found and skipped in input table':
            result.append('BOM removed from input')
        else:
            result.append(warning)
    return result


def calc_file_md5(fname):
    import hashlib
    hash_md5 = hashlib.md5()
    with open(fname, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_md5.update(chunk)
    return hash_md5.hexdigest()


def natural_random(low, high):
    if low <= 0 and high >= 0 and random.randint(0, 2) == 0:
        return 0
    k = random.randint(0, 8)
    if k < 2:
        return low + k
    if k > 6:
        return high - 8 + k
    return random.randint(low, high)


def randomly_quote_field(src, delim):
    if src.find('"') != -1 or src.find(delim) != -1 or src.find('\n') != -1 or src.find('\r') != -1 or random.randint(0, 1) == 1:
        spaces_before = ' ' * random.randint(0, 2) if delim != ' ' else ''
        spaces_after = ' ' * random.randint(0, 2) if delim != ' ' else ''
        escaped = src.replace('"', '""')
        return '{}"{}"{}'.format(spaces_before, escaped, spaces_after)
    return src


def simple_join(fields, delim):
    result = delim.join(fields)
    if result.count(delim) + 1 != len(fields):
        raise RuntimeError('Unable to use simple policy')
    return result


def random_whitespace_join(fields):
    result = ' ' * random.randint(0, 5)
    for f in fields:
        result += f + ' ' * random.randint(1, 5)
    return result


def randomly_join_quoted(fields, delim):
    efields = list()
    for field in fields:
        efields.append(randomly_quote_field(field, delim))
    assert csv_utils.unquote_fields(efields) == fields
    return delim.join(efields)


def random_smart_join(fields, delim, policy):
    if policy == 'simple':
        return simple_join(fields, delim)
    elif policy == 'whitespace':
        assert delim == ' '
        return random_whitespace_join(fields)
    elif policy in ['quoted', 'quoted_rfc']:
        assert delim != '"'
        return randomly_join_quoted(fields, delim)
    elif policy == 'monocolumn':
        assert len(fields) == 1
        return fields[0]
    else:
        raise RuntimeError('Unknown policy')


def find_in_table(table, token):
    for row in table:
        for col in row:
            if col.find(token) != -1:
                return True
    return False


def make_random_comment_lines(num_lines, comment_prefix, delim_to_test):
    lines = []
    str_pool = ['""', '"', delim_to_test, comment_prefix, 'aaa', 'b', '#', ',', '\t', '\\']
    for l in range(num_lines):
        num_sampled = natural_random(0, 10)
        line = []
        while len(line) < num_sampled:
            line.append(random.choice(str_pool))
        lines.append(comment_prefix + ''.join(line))
    return lines


def random_merge_lines(llines, rlines):
    merged = list()
    l = 0
    r = 0
    while l + r < len(llines) + len(rlines):
        lleft = len(llines) - l
        rleft = len(rlines) - r
        v = random.randint(0, lleft + rleft - 1)
        if v < lleft:
            merged.append(llines[l])
            l += 1
        else:
            merged.append(rlines[r])
            r += 1
    assert len(merged) == len(llines) + len(rlines)
    return merged


def table_to_csv_string_random(table, delim, policy, comment_prefix=None):
    lines = [random_smart_join(row, delim, policy) for row in table]
    if comment_prefix is not None:
        num_comment_lines = random.randint(0, len(table) * 2)
        comment_lines = make_random_comment_lines(num_comment_lines, comment_prefix, delim)
        lines = random_merge_lines(lines, comment_lines)
    line_separator = random.choice(line_separators)
    result = line_separator.join(lines)
    if random.choice([True, False]):
        result += line_separator
    return result


def string_to_randomly_encoded_stream(src_str):
    encoding = random.choice(['utf-8', 'latin-1', None])
    if encoding is None:
        return (io.StringIO(src_str), None)
    return (io.BytesIO(src_str.encode(encoding)), encoding)


def write_and_parse_back(table, encoding, delim, policy):
    stream = io.BytesIO() if encoding is not None else io.StringIO()
    line_separator = random.choice(line_separators)
    writer = rbql_csv.CSVWriter(stream, False, encoding, delim, policy, line_separator)
    writer._write_all(table)
    assert not len(writer.get_warnings())
    stream.seek(0)
    record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim=delim, policy=policy)
    parsed_table = record_iterator.get_all_records()
    stream.close()
    return parsed_table



########################################################################################################
# Below are some ad-hoc functions:
########################################################################################################


def make_random_decoded_binary_csv_entry(min_len, max_len, restricted_chars):
    strlen = random.randint(min_len, max_len)
    char_codes = list(range(256))
    if restricted_chars is None:
        restricted_chars = []
    restricted_chars = [ord(c) for c in restricted_chars]
    char_codes = [i for i in char_codes if i not in restricted_chars]
    data_bytes = list()
    for i in range(strlen):
        data_bytes.append(random.choice(char_codes))
    binary_data = bytes(bytearray(data_bytes))
    decoded_binary = binary_data.decode('latin-1')
    assert decoded_binary.encode('latin-1') == binary_data
    return decoded_binary


def generate_random_decoded_binary_table(max_num_rows, max_num_cols, restricted_chars):
    num_rows = natural_random(1, max_num_rows)
    num_cols = natural_random(1, max_num_cols)
    good_keys = ['Hello', 'Avada Kedavra ', '>> ??????', '128', '#3q295 fa#(@*$*)', ' abc defg ', 'NR', 'a1', 'a2']
    result = list()
    good_column = random.randint(0, num_cols - 1)
    for r in range(num_rows):
        result.append(list())
        for c in range(num_cols):
            if c == good_column:
                result[-1].append(random.choice(good_keys))
            else:
                result[-1].append(make_random_decoded_binary_csv_entry(0, 20, restricted_chars))
    return result


def make_random_unicode_entry(min_len, max_len, restricted_chars):
    strlen = random.randint(min_len, max_len)
    restricted_codes = [ord(c) for c in restricted_chars]
    # Create a list of unicode characters within the range 0000-D7FF: Basic Multilingual Plane
    result = list()
    while len(result) < strlen:
        v = random.randrange(0xD7FF)
        if v not in restricted_codes:
            result.append(chr(v))
    return ''.join(result)


def generate_random_unicode_table(max_num_rows, max_num_cols, restricted_chars):
    num_rows = natural_random(1, max_num_rows)
    num_cols = natural_random(1, max_num_cols)
    good_keys = ['Привет!', 'Бабушка', ' ??????', '128', '3q295 fa#(@*$*)', ' abc defg ', 'NR', 'a1', 'a2']
    result = list()
    good_column = random.randint(0, num_cols - 1)
    for r in range(num_rows):
        result.append(list())
        for c in range(num_cols):
            if c == good_column:
                result[-1].append(random.choice(good_keys))
            else:
                result[-1].append(make_random_unicode_entry(0, 20, restricted_chars))
    return result


def make_random_csv_fields_naive(num_fields, max_field_len):
    available = [',', '"', 'a', 'b', 'c', 'd']
    result = list()
    for fn in range(num_fields):
        flen = natural_random(0, max_field_len)
        chosen = list()
        for i in range(flen):
            chosen.append(random.choice(available))
        result.append(''.join(chosen))
    return result



def make_random_csv_records_naive():
    result = list()
    for num_test in range(1000):
        num_fields = random.randint(1, 11)
        max_field_len = 25
        fields = make_random_csv_fields_naive(num_fields, max_field_len)
        csv_line = random_smart_join(fields, ',', 'quoted')
        defective_escaping = random.randint(0, 1)
        if defective_escaping:
            defect_pos = random.randint(0, len(csv_line))
            csv_line = csv_line[:defect_pos] + '"' + csv_line[defect_pos:]
        result.append((fields, csv_line, defective_escaping))
    return result


def normalize_newlines_in_fields(table):
    for row in table:
        for c in range(len(row)):
            row[c] = row[c].replace('\r\n', '\n')
            row[c] = row[c].replace('\r', '\n')


def randomly_replace_columns_dictionary_style(query):
    adjusted_query = query
    for prefix in ['a', 'b']:
        var_regex = r'''(?:^|[^_a-zA-Z0-9])(?:{}\.([_a-zA-Z][_a-z0-9A-Z]*))'''.format(prefix)
        matches = list(re.finditer(var_regex, query))
        for m in matches:
            if random.randint(0, 1):
                continue
            column_name = m.group(1)
            quote_style = "'" if random.randint(0, 1) else '"'
            adjusted_query = adjusted_query.replace('{}.{}'.format(prefix, column_name), '{}[{}{}{}]'.format(prefix, quote_style, column_name, quote_style))
    return adjusted_query


def table_has_records_with_comment_prefix(table, comment_prefix):
    for r in table:
        if r[0].startswith(comment_prefix):
            return True
    return False


class TestHeaderParsing(unittest.TestCase):
    def test_dictionary_variables_parsing(self):
        query = 'select a["foo bar"], a["foo"], max(a["foo"], a["lambda-beta{\'gamma\'}"]), a1, a2, a.epsilon'
        header_columns_names = ['foo', 'foo bar', 'max', "lambda-beta{'gamma'}", "lambda-beta{'gamma2'}", "eps\\ilon", "omega", "1", "2", "....", "["]
        expected_variables_map = {'a["foo"]': vinf(True, 0), 'a["foo bar"]': vinf(True, 1), 'a["max"]': vinf(True, 2), "a[\"lambda-beta{'gamma'}\"]": vinf(True, 3), 'a["eps\\\\ilon"]': vinf(True, 5), 'a["1"]': vinf(True, 7), 'a["2"]': vinf(True, 8), 'a["["]': vinf(True, 10), "a['foo']": vinf(False, 0), "a['foo bar']": vinf(False, 1), "a['max']": vinf(False, 2), "a['lambda-beta{\\'gamma\\'}']": vinf(False, 3), "a['eps\\\\ilon']": vinf(False, 5), "a['1']": vinf(False, 7), "a['2']": vinf(False, 8), "a['[']": vinf(False, 10)}
        actual_variables_map = {}
        rbql_engine.parse_dictionary_variables(query, 'a', header_columns_names, actual_variables_map)
        self.assertEqual(expected_variables_map, actual_variables_map)

    def test_attribute_variables_parsing(self):
        query = 'select a["foo bar"], a1, a2, a.epsilon, a._name + a.Surname, a["income"]'
        header_columns_names = ['epsilon', 'foo bar', '_name', "Surname", "income", "...", "2", "200"]
        expected_variables_map = {'a.epsilon': vinf(True, 0), 'a._name': vinf(True, 2), "a.Surname": vinf(True, 3)}
        actual_variables_map = {}
        rbql_engine.parse_attribute_variables(query, 'a', header_columns_names, 'CSV header line', actual_variables_map)
        self.assertEqual(expected_variables_map, actual_variables_map)


class TestSplitMethods(unittest.TestCase):
    def test_split(self):
        self.assertEqual(csv_utils.split_quoted_str(' aaa, " aaa, bbb " , ccc , ddd ', ',', True)[0], [' aaa', ' " aaa, bbb " ', ' ccc ', ' ddd '])
        self.assertEqual(csv_utils.split_quoted_str(' aaa, " aaa, bbb " , ccc , ddd ', ',', False)[0], [' aaa', ' aaa, bbb ', ' ccc ', ' ddd '])


        test_cases = list()
        test_cases.append(('hello,world', (['hello', 'world'], False)))
        test_cases.append(('hello,"world"', (['hello', 'world'], False)))
        test_cases.append(('"abc"', (['abc'], False)))
        test_cases.append(('abc', (['abc'], False)))
        test_cases.append(('', ([''], False)))
        test_cases.append((',', (['', ''], False)))
        test_cases.append((',,,', (['', '', '', ''], False)))
        test_cases.append((',"",,,', (['', '', '', '', ''], False)))
        test_cases.append(('"","",,,""', (['', '', '', '', ''], False)))
        test_cases.append(('"aaa,bbb",', (['aaa,bbb', ''], False)))
        test_cases.append(('"aaa,bbb",ccc', (['aaa,bbb', 'ccc'], False)))
        test_cases.append(('"aaa,bbb","ccc"', (['aaa,bbb', 'ccc'], False)))
        test_cases.append(('"aaa,bbb","ccc,ddd"', (['aaa,bbb', 'ccc,ddd'], False)))
        test_cases.append((' "aaa,bbb" ,  "ccc,ddd" ', (['aaa,bbb', 'ccc,ddd'], False)))
        test_cases.append(('"aaa,bbb",ccc,ddd', (['aaa,bbb', 'ccc', 'ddd'], False)))
        test_cases.append(('"a"aa" a,bbb",ccc,ddd', (['"a"aa" a', 'bbb"', 'ccc', 'ddd'], True)))
        test_cases.append(('"aa, bb, cc",ccc",ddd', (['aa, bb, cc', 'ccc"', 'ddd'], True)))
        test_cases.append(('hello,world,"', (['hello', 'world', '"'], True)))
        test_cases.append((' aaa, " aaa, bbb " , ccc , ddd ', ([' aaa', ' aaa, bbb ', ' ccc ', ' ddd '], False)))
        test_cases.append((' aaa ,bbb ,ccc , ddd ', ([' aaa ', 'bbb ', 'ccc ', ' ddd '], False)))

        for tc in test_cases:
            src = tc[0]
            expected_dst = tc[1]
            warning_expected = expected_dst[1]
            test_dst = csv_utils.split_quoted_str(tc[0], ',')
            self.assertEqual(expected_dst, test_dst, msg='\nsrc: {}\ntest_dst: {}\nexpected_dst: {}\n'.format(src, test_dst, expected_dst))

            test_dst_preserved = csv_utils.split_quoted_str(tc[0], ',', True)
            self.assertEqual(test_dst[1], test_dst_preserved[1])
            self.assertEqual(','.join(test_dst_preserved[0]), tc[0], 'preserved split failure')
            if not warning_expected:
                self.assertEqual(test_dst[0], csv_utils.unquote_fields(test_dst_preserved[0]))


    def test_unquote(self):
        test_cases = list()
        test_cases.append(('  "hello, ""world"" aa""  " ', 'hello, "world" aa"  '))
        for tc in test_cases:
            src, expected = tc
            test_dst = csv_utils.unquote_field(src)
            self.assertEqual(expected, test_dst)


    def test_split_whitespaces(self):
        test_cases = list()
        test_cases.append(('hello world', (['hello', 'world'], False)))
        test_cases.append(('hello   world', (['hello', 'world'], False)))
        test_cases.append(('   hello   world   ', (['hello', 'world'], False)))
        test_cases.append(('     ', ([], False)))
        test_cases.append(('', ([], False)))
        test_cases.append(('   a   b  c d ', (['a', 'b', 'c', 'd'], False)))

        test_cases.append(('hello world', (['hello', 'world'], True)))
        test_cases.append(('hello   world', (['hello  ', 'world'], True)))
        test_cases.append(('   hello   world   ', (['   hello  ', 'world   '], True)))
        test_cases.append(('     ', ([], True)))
        test_cases.append(('', ([], True)))
        test_cases.append(('   a   b  c d ', (['   a  ', 'b ', 'c', 'd '], True)))

        for tc in test_cases:
            src = tc[0]
            expected_dst, preserve_whitespaces = tc[1]
            test_dst = csv_utils.split_whitespace_separated_str(src, preserve_whitespaces)
            self.assertEqual(test_dst, expected_dst)


    def test_random(self):
        random_records = make_random_csv_records_naive()
        for ir, rec in enumerate(random_records):
            expected_fields = rec[0]
            escaped_entry = rec[1]
            expected_warning = rec[2]
            test_fields, test_warning = csv_utils.split_quoted_str(escaped_entry, ',')
            test_fields_preserved, test_warning_preserved = csv_utils.split_quoted_str(escaped_entry, ',', True)
            self.assertEqual(','.join(test_fields_preserved), escaped_entry)
            self.assertEqual(expected_warning, test_warning)
            self.assertEqual(test_warning_preserved, test_warning)
            self.assertEqual(test_fields, csv_utils.unquote_fields(test_fields_preserved))
            if not expected_warning:
                self.assertEqual(expected_fields, test_fields)



class TestLineSplit(unittest.TestCase):
    def test_split_lines_custom(self):
        test_cases = list()
        test_cases.append(('', []))
        test_cases.append(('hello', ['hello']))
        test_cases.append(('hello\nworld', ['hello', 'world']))
        test_cases.append(('hello\rworld\n', ['hello', 'world']))
        test_cases.append(('hello\r\nworld\rhello world\nhello\n', ['hello', 'world', 'hello world', 'hello']))
        for tc in test_cases:
            src, expected_res = tc
            stream, encoding = string_to_randomly_encoded_stream(src)
            line_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim=None, policy=None, chunk_size=6, line_mode=True)
            test_res = line_iterator._get_all_rows()
            stream.close()
            self.assertEqual(expected_res, test_res)

    def test_split_chunk_sizes(self):
        source_tokens = ['', 'defghIJKLMN', 'a', 'bc'] + ['\n', '\r\n', '\r']
        for test_case in range(1000):
            num_tokens = random.randint(0, 12)
            chunk_size = random.randint(1, 5) if random.randint(0, 1) else random.randint(1, 100)
            src = ''
            for tnum in range(num_tokens):
                token = random.choice(source_tokens)
                src += token
            stream, encoding = string_to_randomly_encoded_stream(src)
            line_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim=None, policy=None, chunk_size=chunk_size, line_mode=True)
            test_res = line_iterator._get_all_rows()
            stream.close()
            expected_res = src.splitlines()
            self.assertEqual(expected_res, test_res)

class TestRecordIterator(unittest.TestCase):
    def test_iterator(self):
        for _test_num in range(100):
            table = generate_random_decoded_binary_table(10, 10, ['\r', '\n'])
            delims = ['\t', ',', ';', '|']
            delim = random.choice(delims)
            table_has_delim = find_in_table(table, delim)
            policy = 'quoted' if table_has_delim else random.choice(['quoted', 'simple'])
            csv_data = table_to_csv_string_random(table, delim, policy)
            stream, encoding = string_to_randomly_encoded_stream(csv_data)

            record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim=delim, policy=policy)
            parsed_table = record_iterator.get_all_records()
            stream.close()
            self.assertEqual(table, parsed_table)

            parsed_table = write_and_parse_back(table, encoding, delim, policy)
            self.assertEqual(table, parsed_table)


    def test_iterator_unicode(self):
        for _test_num in range(100):
            table = generate_random_unicode_table(10, 10, ['\r', '\n'])
            delims = ['\t', ',', ';', '|', 'Д', 'Ф', '\u2063']
            delim = random.choice(delims)
            table_has_delim = find_in_table(table, delim)
            policy = 'quoted' if table_has_delim else random.choice(['quoted', 'simple'])
            csv_data = table_to_csv_string_random(table, delim, policy)
            encoding = 'utf-8'
            stream = io.BytesIO(csv_data.encode(encoding))

            record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim=delim, policy=policy)
            parsed_table = record_iterator.get_all_records()
            stream.close()
            self.assertEqual(table, parsed_table)

            parsed_table = write_and_parse_back(table, encoding, delim, policy)
            self.assertEqual(table, parsed_table)


    def test_iterator_rfc(self):
        for _test_num in range(100):
            table = generate_random_decoded_binary_table(10, 10, None)
            delims = ['\t', ',', ';', '|']
            delim = random.choice(delims)
            policy = 'quoted_rfc'
            csv_data = table_to_csv_string_random(table, delim, policy)
            normalize_newlines_in_fields(table) # XXX normalizing '\r' -> '\n' because record iterator doesn't preserve original separators
            stream, encoding = string_to_randomly_encoded_stream(csv_data)

            record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim=delim, policy=policy)
            parsed_table = record_iterator.get_all_records()
            stream.close()
            self.assertEqual(table, parsed_table)

            parsed_table = write_and_parse_back(table, encoding, delim, policy)
            self.assertEqual(table, parsed_table)


    def test_iterator_rfc_comments(self):
        for _test_num in range(200):
            table = generate_random_decoded_binary_table(10, 10, None)
            comment_prefix = random.choice(['#', '>>'])
            if table_has_records_with_comment_prefix(table, comment_prefix):
                continue # Instead of complicating the generation procedure just skip the tables which were generated "incorrectly"
            delims = ['\t', ',', ';', '|']
            delim = random.choice(delims)
            policy = 'quoted_rfc'
            csv_data = table_to_csv_string_random(table, delim, policy, comment_prefix=comment_prefix)
            normalize_newlines_in_fields(table) # XXX normalizing '\r' -> '\n' because record iterator doesn't preserve original separators
            stream, encoding = string_to_randomly_encoded_stream(csv_data)

            record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim=delim, policy=policy, comment_prefix=comment_prefix)
            parsed_table = record_iterator.get_all_records()
            stream.close()
            self.assertEqual(table, parsed_table)

            parsed_table = write_and_parse_back(table, encoding, delim, policy)
            self.assertEqual(table, parsed_table)


    def test_multiline_fields(self):
        data_lines = []
        data_lines.append('foo, bar,aaa')
        data_lines.append('test,"hello, bar", "aaa ')
        data_lines.append('test","hello, bar", "bbb ')
        data_lines.append('foo, bar,aaa')
        data_lines.append('foo, ""bar"",aaa')
        data_lines.append('foo, test","hello, bar", "bbb "')
        data_lines.append('foo, bar,aaa')
        csv_data = '\n'.join(data_lines)
        stream, encoding = string_to_randomly_encoded_stream(csv_data)
        table = [['foo', ' bar', 'aaa'], ['test', 'hello, bar', 'aaa \ntest', 'hello, bar', 'bbb \nfoo, bar,aaa\nfoo, "bar",aaa\nfoo, test', "hello, bar", 'bbb '], ['foo', ' bar', 'aaa']]
        delim = ','
        policy = 'quoted_rfc'

        record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim=delim, policy=policy)
        parsed_table = record_iterator.get_all_records()
        stream.close()
        self.assertEqual(table, parsed_table)
        parsed_table = write_and_parse_back(table, encoding, delim, policy)
        self.assertEqual(table, parsed_table)


    def test_strip_whitespaces_true(self):
        data_lines = []
        data_lines.append('aa,bb,cc')
        data_lines.append('  aa ,  bb  , cc  ')
        data_lines.append('\ta  aa ,  bb \t , cc  c')
        csv_data = '\n'.join(data_lines)
        stream, encoding = string_to_randomly_encoded_stream(csv_data)
        table = [['aa', 'bb', 'cc'], ['aa', 'bb', 'cc'], ['a  aa', 'bb', 'cc  c']]
        delim = ','
        policy = 'simple'
        record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim=delim, policy=policy, strip_whitespaces=True)
        parsed_table = record_iterator.get_all_records()
        stream.close()
        self.assertEqual(table, parsed_table)
        parsed_table = write_and_parse_back(table, encoding, delim, policy)
        self.assertEqual(table, parsed_table)


    def test_strip_whitespaces_false(self):
        data_lines = []
        data_lines.append('aa,bb,cc')
        data_lines.append('  aa ,  bb  , cc  ')
        data_lines.append('\ta  aa ,  bb \t , cc  c')
        csv_data = '\n'.join(data_lines)
        stream, encoding = string_to_randomly_encoded_stream(csv_data)
        table = [['aa', 'bb', 'cc'], ['  aa ', '  bb  ', ' cc  '], ['\ta  aa ', '  bb \t ', ' cc  c']]
        delim = ','
        policy = 'simple'
        record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim=delim, policy=policy, strip_whitespaces=False)
        parsed_table = record_iterator.get_all_records()
        stream.close()
        self.assertEqual(table, parsed_table)
        parsed_table = write_and_parse_back(table, encoding, delim, policy)
        self.assertEqual(table, parsed_table)

    def test_multicharacter_separator_parsing(self):
        data_lines = []
        data_lines.append('aaa:=)bbb:=)ccc')
        data_lines.append('aaa :=) bbb :=)ccc ')
        expected_table = [['aaa', 'bbb', 'ccc'], ['aaa ', ' bbb ', 'ccc ']]
        csv_data = '\n'.join(data_lines)
        stream = io.StringIO(csv_data)
        delim = ':=)'
        policy = 'simple'
        encoding = None
        record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim, policy)
        parsed_table = record_iterator.get_all_records()
        stream.close()
        self.assertEqual(expected_table, parsed_table)

        parsed_table = write_and_parse_back(expected_table, encoding, delim, policy)
        self.assertEqual(expected_table, parsed_table)


    def test_whitespace_separated_parsing(self):
        data_lines = []
        data_lines.append('hello world')
        data_lines.append('   hello   world  ')
        data_lines.append('hello   world  ')
        data_lines.append('  hello   ')
        data_lines.append('  hello   world')
        expected_table = [['hello', 'world'], ['hello', 'world'], ['hello', 'world'], ['hello'], ['hello', 'world']]
        csv_data = '\n'.join(data_lines)
        stream = io.StringIO(csv_data)
        delim = ' '
        policy = 'whitespace'
        encoding = None
        record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim, policy)
        parsed_table = record_iterator.get_all_records()
        stream.close()
        self.assertEqual(expected_table, parsed_table)

        parsed_table = write_and_parse_back(expected_table, encoding, delim, policy)
        self.assertEqual(expected_table, parsed_table)


    def test_monocolumn_separated_parsing(self):
        for i in range(10):
            self.maxDiff = None
            table = list()
            num_rows = random.randint(1, 30)
            for irow in range(num_rows):
                min_len = 0 if irow + 1 < num_rows else 1
                table.append([make_random_decoded_binary_csv_entry(min_len, 20, restricted_chars=['\r', '\n'])])
            csv_data = table_to_csv_string_random(table, None, 'monocolumn')
            stream = io.StringIO(csv_data)
            delim = None
            policy = 'monocolumn'
            encoding = None
            record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim, policy)
            parsed_table = record_iterator.get_all_records()
            stream.close()
            self.assertEqual(table, parsed_table)

            parsed_table = write_and_parse_back(table, encoding, delim, policy)
            self.assertEqual(table, parsed_table)


    def test_monocolumn_write_failure(self):
        encoding = None
        writer_stream =  io.StringIO()
        delim = None
        policy = 'monocolumn'
        table = [["this will not", "work"], ["as monocolumn", "table"]]
        writer = rbql_csv.CSVWriter(writer_stream, True, encoding, delim, policy, '\n')
        with self.assertRaises(Exception) as cm:
            writer._write_all(table)
        e = cm.exception
        self.assertTrue(str(e).find('some records have more than one field') != -1)


    def test_output_warnings(self):
        encoding = None
        writer_stream = io.StringIO()
        delim = ','
        policy = 'simple'
        table = [["hello,world", None], ["hello", "world"]]
        writer = rbql_csv.CSVWriter(writer_stream, False, encoding, delim, policy, '\n')
        writer._write_all(table)
        writer_stream.seek(0)
        actual_data = writer_stream.getvalue()
        expected_data = 'hello,world,\nhello,world\n'
        self.assertEqual(expected_data, actual_data)
        actual_warnings = writer.get_warnings()
        expected_warnings = ['None values in output were replaced by empty strings', 'Some output fields contain separator']
        self.assertEqual(expected_warnings, actual_warnings)


    def test_utf_decoding_errors(self):
        table = [['hello', u'\x80\x81\xffThis unicode string encoded as latin-1 is not a valid utf-8\xaa\xbb\xcc'], ['hello', 'world']]
        delim = ','
        policy = 'simple'
        encoding = 'latin-1'
        csv_data = table_to_csv_string_random(table, delim, policy)
        stream = io.BytesIO(csv_data.encode('latin-1'))
        record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim, policy)
        parsed_table = record_iterator.get_all_records()
        stream.close()
        self.assertEqual(table, parsed_table)

        parsed_table = write_and_parse_back(table, encoding, delim, policy)
        self.assertEqual(table, parsed_table)

        stream = io.BytesIO(csv_data.encode('latin-1'))
        with self.assertRaises(Exception) as cm:
            record_iterator = rbql_csv.CSVRecordIterator(stream, 'utf-8', delim=delim, policy=policy)
            parsed_table = record_iterator.get_all_records()
            stream.close()
        e = cm.exception
        self.assertTrue(str(e).find('Unable to decode input table as UTF-8') != -1)


    def test_bom_warning(self):
        table = list()
        table.append([u'\xef\xbb\xbfcde', '1234'])
        table.append(['abc', '1234'])
        table.append(['abc', '1234'])
        table.append(['efg', '100'])
        table.append(['abc', '100'])
        table.append(['cde', '12999'])
        table.append(['aaa', '2000'])
        table.append(['abc', '100'])
        delim = ','
        policy = 'simple'
        encoding = 'latin-1'
        csv_data = table_to_csv_string_random(table, delim, policy)
        stream = io.BytesIO(csv_data.encode('latin-1'))
        record_iterator = rbql_csv.CSVRecordIterator(stream, encoding, delim, policy)
        parsed_table = record_iterator.get_all_records()
        stream.close()
        expected_warnings = ['UTF-8 Byte Order Mark (BOM) was found and skipped in input table']
        actual_warnings = record_iterator.get_warnings()
        self.assertEqual(expected_warnings, actual_warnings)
        expected_table = copy.deepcopy(table)
        expected_table[0][0] = 'cde'
        self.assertEqual(expected_table, parsed_table)


def make_column_variable(column_name):
    if re.match('^[_a-zA-Z][_a-zA-Z0-9]*$', column_name):
        return 'a.' + column_name
    quote_char = random.choice(['"', "'"])
    return 'a[' + quote_char + rbql_engine.python_string_escape_column_name(column_name, quote_char) + quote_char + ']'


class TestRBQLSimple(unittest.TestCase):
    def test_simple_case(self):
        input_table = list()
        input_table.append(['name', 'value'])
        input_table.append(['abc', '1234'])
        input_table.append(['abc', '1234'])
        input_table.append(['efg', '100'])
        input_table.append(['abc', '100'])
        input_table.append(['cde', '12999'])
        input_table.append(['aaa', '2000'])
        input_table.append(['abc', '100'])

        expected_table = list()
        expected_table.append(['name', 'col2'])
        expected_table.append(['abc', '12340'])
        expected_table.append(['abc', '12340'])
        expected_table.append(['abc', '1000'])
        expected_table.append(['abc', '1000'])

        delim = ','
        policy = 'quoted'
        csv_data = table_to_csv_string_random(input_table, delim, policy)
        input_stream, encoding = string_to_randomly_encoded_stream(csv_data)

        input_iterator = rbql_csv.CSVRecordIterator(input_stream, encoding, delim=delim, policy=policy, has_header=True)

        output_stream = io.BytesIO() if encoding is not None else io.StringIO()
        output_writer = rbql_csv.CSVWriter(output_stream, False, encoding, delim, policy)

        warnings = []
        rbql.query('select a.name, int(a.value) * 10 where a.name == "abc"', input_iterator, output_writer, warnings)
        input_stream.close()
        self.assertEqual(warnings, [])

        output_stream.seek(0)
        output_iterator = rbql_csv.CSVRecordIterator(output_stream, encoding, delim=delim, policy=policy)
        output_table = output_iterator.get_all_records()
        output_stream.close()
        self.assertEqual(expected_table, output_table)


    def _do_test_random_headers(self):
        num_rows = natural_random(0, 10)
        num_cols = natural_random(2, 10)
        input_table = list()
        expected_table = list()

        header_row = list()
        for col in range (num_cols):
            while True:
                if random.choice([True, False]):
                    field_name_len = natural_random(1, 10)
                    field_name_bytes = []
                    for c in range(field_name_len):
                        field_name_bytes.append(random.randint(32, 126))
                    field_name = bytes(bytearray(field_name_bytes)).decode('ascii')
                else:
                    field_name = random.choice(['_foo', 'bar', 'Bar', '__foo', 'a', 'b', 'A', 'B'])
                if field_name not in header_row:
                    header_row.append(field_name)
                    break
        input_table.append(header_row[:])
        expected_table.append(header_row[:])
        all_col_nums = list(range(num_cols))
        query_col_1 = random.choice(all_col_nums)
        all_col_nums.remove(query_col_1)
        query_col_2 = random.choice(all_col_nums)
        for row_id in range(num_rows):
            is_good_row = True
            row = list()
            for col_id in range(num_cols):
                if col_id == query_col_1:
                    field_value = random.choice(['foo bar good', 'foo bar bad'])
                    if field_value != 'foo bar good':
                        is_good_row = False
                elif col_id == query_col_2:
                    field_value = random.choice(['10', '0'])
                    if field_value != '10':
                        is_good_row = False
                else:
                    field_value = make_random_decoded_binary_csv_entry(0, 10, restricted_chars=['\r', '\n'])
                row.append(field_value)
            input_table.append(row[:])
            if is_good_row:
                expected_table.append(row[:])
        query_col_name_1 = make_column_variable(header_row[query_col_1])
        query_col_name_2 = make_column_variable(header_row[query_col_2])
        query = 'select * where ({}.endswith("good") and int({}) * 2 == 20)'.format(query_col_name_1, query_col_name_2)

        delim = ','
        policy = 'quoted'
        csv_data = table_to_csv_string_random(input_table, delim, policy)
        encoding = 'latin-1'
        stream = io.BytesIO(csv_data.encode(encoding))
        input_stream, encoding = string_to_randomly_encoded_stream(csv_data)

        input_iterator = rbql_csv.CSVRecordIterator(input_stream, encoding, delim=delim, policy=policy, has_header=True)

        output_stream = io.BytesIO() if encoding is not None else io.StringIO()
        output_writer = rbql_csv.CSVWriter(output_stream, False, encoding, delim, policy)

        warnings = []
        rbql.query(query, input_iterator, output_writer, warnings)
        input_stream.close()
        self.assertEqual(warnings, [])

        output_stream.seek(0)
        output_iterator = rbql_csv.CSVRecordIterator(output_stream, encoding, delim=delim, policy=policy)
        output_table = output_iterator.get_all_records()
        output_stream.close()
        self.assertEqual(expected_table, output_table)


    def test_random_headers(self):
        for i in range(10):
            self._do_test_random_headers()


class TestRBQLWithCSV(unittest.TestCase):
    # TODO add test with whitespace strip in join table.
    def process_test_case(self, tmp_tests_dir, test_case):
        test_name = test_case['test_name']
        minimal_minor_python_version = int(test_case.get('minimal_python_version', '3.0').split('.')[1])
        if python_minor_version < minimal_minor_python_version:
            print('Skipping {}: python version must be at least {}. Interpreter version is {}'.format(test_name, minimal_minor_python_version, python_minor_version))
            return
        query = test_case.get('query_python', None)
        if query is None:
            return
        debug_mode = test_case.get('debug_mode', False)
        randomly_replace_var_names = test_case.get('randomly_replace_var_names', True)
        with_headers = test_case.get('with_headers', False)
        strip_whitespaces = test_case.get('strip_whitespaces', False)
        input_table_path = test_case['input_table_path']
        query = query.replace('###UT_TESTS_DIR###', script_dir)
        if randomly_replace_var_names:
            query = randomly_replace_columns_dictionary_style(query)
        input_table_path = os.path.join(script_dir, input_table_path)
        expected_output_table_path = test_case.get('expected_output_table_path', None)
        if expected_output_table_path is not None:
            expected_output_table_path = os.path.join(script_dir, expected_output_table_path)
            expected_md5 = calc_file_md5(expected_output_table_path)
            output_file_name = os.path.basename(expected_output_table_path)
            actual_output_table_path = os.path.join(tmp_tests_dir, output_file_name) 
        else:
            actual_output_table_path = os.path.join(tmp_tests_dir, 'expected_empty_file') 
        absolute_output_table_path = test_case.get('absolute_output_table_path', None)
        if absolute_output_table_path is not None:
            actual_output_table_path = absolute_output_table_path

        expected_error = test_case.get('expected_error', None) or test_case.get('expected_error_py', None)
        expected_warnings = test_case.get('expected_warnings', [])
        delim = test_case['csv_separator']
        policy = test_case['csv_policy']
        encoding = test_case['csv_encoding']
        comment_prefix = test_case.get('comment_prefix', None)
        comment_regex = test_case.get('comment_regex', None)
        output_format = test_case.get('output_format', 'input')

        out_delim, out_policy = (delim, policy) if output_format == 'input' else rbql_csv.interpret_named_csv_format(output_format)
        if debug_mode:
            rbql_csv.set_debug_mode()
        warnings = []
        error_type, error_msg = None, None
        try:
            rbql_csv.query_csv(query, input_table_path, delim, policy, actual_output_table_path, out_delim, out_policy, encoding, warnings, with_headers, comment_prefix, strip_whitespaces=strip_whitespaces, comment_regex=comment_regex)
        except Exception as e:
            if debug_mode:
                raise
            error_type, error_msg = rbql.exception_to_error_info(e)

        self.assertTrue((expected_error is not None) == (error_type is not None), 'Inside json test: "{}". Expected error: {}, error_type, error_msg: {}'.format(test_name, expected_error, error_type, error_msg))
        if expected_error is not None:
            self.assertTrue(error_msg.find(expected_error) != -1, 'Inside json test: "{}", Expected error: "{}", Actual error: "{}"'.format(test_name, expected_error, error_msg))
        else:
            actual_md5 = calc_file_md5(actual_output_table_path)
            self.assertTrue(expected_md5 == actual_md5, 'md5 missmatch in test "{}". Expected table: {}, Actual table: {}'.format(test_name, expected_output_table_path, actual_output_table_path))

        warnings = sorted(normalize_warnings(warnings))
        expected_warnings = sorted(expected_warnings)
        self.assertEqual(expected_warnings, warnings, 'Inside json test: "{}". Expected warnings: {}, Actual warnings: {}'.format(test_name, expected_warnings, warnings))



    def test_json_scenarios(self):
        tests_file = os.path.join(script_dir, 'csv_unit_tests.json')
        tmp_dir = tempfile.gettempdir()
        tmp_tests_dir = 'rbql_csv_unit_tests_dir_{}_{}'.format(time.time(), random.randint(1, 100000000)).replace('.', '_')
        tmp_tests_dir = os.path.join(tmp_dir, tmp_tests_dir)
        os.mkdir(tmp_tests_dir)
        with open(tests_file) as f:
            tests = json.loads(f.read())
            filtered_tests = [t for t in tests if t.get('skip_others', False)]
            if len(filtered_tests):
                tests = filtered_tests
            for test in tests:
                self.process_test_case(tmp_tests_dir, test)
        shutil.rmtree(tmp_tests_dir)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--create_random_csv_table', metavar='FILE', help='create random csv table')
    parser.add_argument('--create_big_csv_table', metavar='FILE', help='create random csv table for speed test')
    parser.add_argument('--dummy_csv_speedtest', metavar='FILE', help='run dummy CSV speedtest')
    args = parser.parse_args()

    if args.create_random_csv_table is not None:
        dst_path = args.create_random_csv_table
        random_records = make_random_csv_records_naive()
        with open(dst_path, 'w') as dst:
            for rec in random_records:
                expected_fields = rec[0]
                escaped_entry = rec[1]
                expected_warning = rec[2]
                dst.write('{}\t{}\t{}\n'.format(escaped_entry, expected_warning, ';'.join(expected_fields)))
        return

    if args.dummy_csv_speedtest is not None:
        num_fields = 0
        src_path = args.dummy_csv_speedtest
        with open(src_path, 'r') as src:
            for line in src:
                fields = line.rstrip().split(',')
                num_fields += len(fields)
        print(num_fields)
        return

    if args.create_big_csv_table is not None:
        dst_path = args.create_big_csv_table
        num_rows = 300 * 1000
        with open(dst_path, 'w') as dst:
            for nr in range(num_rows):
                price = str(random.randint(10, 20))
                item = random.choice(['parsley', 'sage', 'rosemary', 'thyme'])
                csv_line = random_smart_join([price, item], ',', 'quoted')
                dst.write(csv_line + '\n')



if __name__ == '__main__':
    main()
