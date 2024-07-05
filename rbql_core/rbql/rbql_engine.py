# -*- coding: utf-8 -*-
from __future__ import unicode_literals
from __future__ import print_function

import sys
import re
import ast
from collections import OrderedDict, defaultdict, namedtuple

import random # For usage inside user queries only.
import datetime # For usage inside user queries only.
import os # For usage inside user queries only.
import math # For usage inside user queries only.
import time # For usage inside user queries only.

from ._version import __version__

# This module must be both python2 and python3 compatible.
# This module works with records only. It is CSV-agnostic.
# Do not add CSV-related logic or variables/functions/objects like "delim", "separator" etc.
# See DEV_README.md for additional info.

# UT JSON - means json Unit Test exists for this case.
# UT JSON CSV - means json csv Unit Test exists for this case.

GROUP_BY = 'GROUP BY'
UPDATE = 'UPDATE'
SELECT = 'SELECT'
JOIN = 'JOIN'
INNER_JOIN = 'INNER JOIN'
LEFT_JOIN = 'LEFT JOIN'
LEFT_OUTER_JOIN = 'LEFT OUTER JOIN'
STRICT_LEFT_JOIN = 'STRICT LEFT JOIN'
ORDER_BY = 'ORDER BY'
WHERE = 'WHERE'
LIMIT = 'LIMIT'
EXCEPT = 'EXCEPT'
WITH = 'WITH'
FROM = 'FROM'

default_statement_groups = [[STRICT_LEFT_JOIN, LEFT_OUTER_JOIN, LEFT_JOIN, INNER_JOIN, JOIN], [SELECT], [ORDER_BY], [WHERE], [UPDATE], [GROUP_BY], [LIMIT], [EXCEPT], [FROM]]

ambiguous_error_msg = 'Ambiguous variable name: "{}" is present both in input and in join tables'
invalid_keyword_in_aggregate_query_error_msg = '"ORDER BY", "UPDATE" and "DISTINCT" keywords are not allowed in aggregate queries'
wrong_aggregation_usage_error = 'Usage of RBQL aggregation functions inside Python expressions is not allowed, see the docs'
numeric_conversion_error = 'Unable to convert value "{}" to int or float. MIN, MAX, SUM, AVG, MEDIAN and VARIANCE aggregate functions convert their string arguments to numeric values'

PY3 = sys.version_info[0] == 3

RBQL_VERSION = __version__

debug_mode = False

class RbqlRuntimeError(Exception):
    pass

class RbqlParsingError(Exception):
    pass

class RbqlIOHandlingError(Exception):
    pass


class InternalBadFieldError(Exception):
    def __init__(self, bad_idx):
        self.bad_idx = bad_idx


class InternalBadKeyError(Exception):
    def __init__(self, bad_key):
        self.bad_key = bad_key


VariableInfo = namedtuple('VariableInfo', ['initialize', 'index'])


class RBQLContext:
    def __init__(self, input_iterator, output_writer, user_init_code):
        self.input_iterator = input_iterator
        self.writer = output_writer
        self.user_init_code = user_init_code

        self.unnest_list = None
        self.top_count = None

        self.like_regex_cache = dict()

        self.sort_key_expression = None

        self.aggregation_stage = 0
        self.aggregation_key_expression = None
        self.functional_aggregators = []

        self.join_map_impl = None
        self.join_map = None
        self.lhs_join_var_expression = None

        self.where_expression = None

        self.select_expression = None

        self.update_expressions = None

        self.variables_init_code = None


def is_str6(val):
    return (PY3 and isinstance(val, str)) or (not PY3 and isinstance(val, basestring))


QueryColumnInfo = namedtuple('QueryColumnInfo', ['table_name', 'column_index', 'column_name', 'is_star', 'alias_name'])


def get_field(root, field_name):
    for f in ast.iter_fields(root):
        if len(f) == 2 and f[0] == field_name:
            return f[1]
    return None


def search_for_as_alias_pseudo_function(root):
    for node in ast.walk(root):
        if not isinstance(node, ast.Call):
            continue
        func_root = get_field(node, 'func')
        if not isinstance(func_root, ast.Name):
            continue
        func_id = get_field(func_root, 'id')
        if (func_id != 'alias_column_as_pseudo_func'):
            continue
        # We found the function node. Since we created the node itself earlier it must have a very specific format: it is a free function call with a single id-like argument.
        args_root = get_field(node, 'args')
        if not args_root or len(args_root) != 1:
            raise RbqlParsingError('Unable to parse "AS" column alias') # Should never happen
        arg_name_node = args_root[0]
        if not isinstance(arg_name_node, ast.Name):
            raise RbqlParsingError('Unable to parse "AS" column alias') # Should never happen
        alias_id = get_field(arg_name_node, 'id')
        if not alias_id:
            raise RbqlParsingError('Unable to parse "AS" column alias') # Should never happen
        return alias_id
    return None


def column_info_from_node(root):
    rbql_star_marker = '__RBQL_INTERNAL_STAR'
    if isinstance(root, ast.Name):
        var_name = get_field(root, 'id')
        if var_name is None:
            return None
        if var_name == rbql_star_marker:
            return QueryColumnInfo(table_name=None, column_index=None, column_name=None, is_star=True, alias_name=None)
        good_column_name_rgx = '^([ab])([0-9][0-9]*)$'
        match_obj = re.match(good_column_name_rgx, var_name)
        if match_obj is not None:
            table_name = match_obj.group(1)
            column_index = int(match_obj.group(2)) - 1
            return QueryColumnInfo(table_name=table_name, column_index=column_index, column_name=None, is_star=False, alias_name=None)
        # Some examples for this branch: NR, NF
        return QueryColumnInfo(table_name=None, column_index=None, column_name=var_name, is_star=False, alias_name=None)
    if isinstance(root, ast.Attribute):
        column_name = get_field(root, 'attr')
        if not column_name:
            return None
        if not is_str6(column_name):
            return None
        var_root = get_field(root, 'value')
        if not isinstance(var_root, ast.Name):
            return None
        table_name = get_field(var_root, 'id')
        if table_name is None or table_name not in ['a', 'b']:
            return None
        if column_name == rbql_star_marker:
            return QueryColumnInfo(table_name=table_name, column_index=None, column_name=None, is_star=True, alias_name=None)
        return QueryColumnInfo(table_name=None, column_index=None, column_name=column_name, is_star=False, alias_name=None)
    if isinstance(root, ast.Subscript):
        var_root = get_field(root, 'value')
        if not isinstance(var_root, ast.Name):
            return None
        table_name = get_field(var_root, 'id')
        if table_name is None or table_name not in ['a', 'b']:
            return None
        slice_root = get_field(root, 'slice')
        if slice_root is None or not isinstance(slice_root, ast.Index):
            return None
        slice_val_root = get_field(slice_root, 'value')
        column_index = None
        column_name = None
        if isinstance(slice_val_root, ast.Str):
            column_name = get_field(slice_val_root, 's')
            table_name = None # We don't need table name for named fields
        elif isinstance(slice_val_root, ast.Num):
            column_index = get_field(slice_val_root, 'n') - 1
        else:
            return None
        if not PY3 and isinstance(column_name, str):
            column_name = column_name.decode('utf-8')
        return QueryColumnInfo(table_name=table_name, column_index=column_index, column_name=column_name, is_star=False, alias_name=None)
    column_alias_name = search_for_as_alias_pseudo_function(root)
    if column_alias_name:
        return QueryColumnInfo(table_name=None, column_index=None, column_name=None, is_star=False, alias_name=column_alias_name)
    return None


def ast_parse_select_expression_to_column_infos(select_expression):
    root = ast.parse(select_expression)
    children = list(ast.iter_child_nodes(root))
    if 'body' not in root._fields:
        raise RbqlParsingError('Unable to parse SELECT expression (error code #117)') # Should never happen
    if len(children) != 1:
        raise RbqlParsingError('Unable to parse SELECT expression (error code #118)') # Should never happen
    root = children[0]
    children = list(ast.iter_child_nodes(root))
    if len(children) != 1:
        raise RbqlParsingError('Unable to parse SELECT expression (error code #119): "{}"'.format(select_expression)) # This can be triggered with `SELECT a = 100`
    root = children[0]
    if isinstance(root, ast.Tuple):
        column_expression_trees = root.elts
        column_infos = [column_info_from_node(ct) for ct in column_expression_trees]
    else:
        column_infos = [column_info_from_node(root)]
    return column_infos


def iteritems6(x):
    if PY3:
        return x.items()
    return x.iteritems()


class RBQLRecord:
    def __init__(self):
        self.storage = dict()

    def __getitem__(self, key):
        try:
            return self.storage[key]
        except KeyError:
            raise InternalBadKeyError(key)

    def __setitem__(self, key, value):
        self.storage[key] = value


def safe_get(record, idx):
    return record[idx] if idx < len(record) else None


def safe_join_get(record, idx):
    try:
        return record[idx]
    except IndexError:
        raise InternalBadFieldError(idx)


def safe_set(record, idx, value):
    try:
        record[idx] = value
    except IndexError:
        raise InternalBadFieldError(idx)


def like_to_regex(pattern):
    p = 0
    i = 0
    converted = ''
    while i < len(pattern):
        if pattern[i] in ['_', '%']:
            converted += re.escape(pattern[p:i])
            p = i + 1
            if pattern[i] == '_':
                converted += '.'
            else:
                converted += '.*'
        i += 1
    converted += re.escape(pattern[p:i])
    return '^' + converted + '$'


class RBQLAggregationToken(object):
    def __init__(self, marker_id, value):
        self.marker_id = marker_id
        self.value = value

    def __str__(self):
        raise TypeError('RBQLAggregationToken')


class NumHandler:
    def __init__(self, start_with_int):
        self.is_int = start_with_int
        self.string_detection_done = False
        self.is_str = False

    def parse(self, val):
        if not self.string_detection_done:
            self.string_detection_done = True
            if is_str6(val):
                self.is_str = True
        if not self.is_str:
            return val
        if self.is_int:
            try:
                return int(val)
            except ValueError:
                self.is_int = False
        try:
            return float(val)
        except ValueError:
            raise RbqlRuntimeError(numeric_conversion_error.format(val)) # UT JSON


class AnyValueAggregator:
    def __init__(self):
        self.stats = dict()

    def increment(self, key, val):
        if key not in self.stats:
            self.stats[key] = val

    def get_final(self, key):
        return self.stats[key]


class MinAggregator:
    def __init__(self):
        self.stats = dict()
        self.num_handler = NumHandler(True)

    def increment(self, key, val):
        val = self.num_handler.parse(val)
        cur_aggr = self.stats.get(key)
        if cur_aggr is None:
            self.stats[key] = val
        else:
            self.stats[key] = min(cur_aggr, val)

    def get_final(self, key):
        return self.stats[key]


class MaxAggregator:
    def __init__(self):
        self.stats = dict()
        self.num_handler = NumHandler(True)

    def increment(self, key, val):
        val = self.num_handler.parse(val)
        cur_aggr = self.stats.get(key)
        if cur_aggr is None:
            self.stats[key] = val
        else:
            self.stats[key] = max(cur_aggr, val)

    def get_final(self, key):
        return self.stats[key]


class SumAggregator:
    def __init__(self):
        self.stats = defaultdict(int)
        self.num_handler = NumHandler(True)

    def increment(self, key, val):
        val = self.num_handler.parse(val)
        self.stats[key] += val

    def get_final(self, key):
        return self.stats[key]


class AvgAggregator:
    def __init__(self):
        self.stats = dict()
        self.num_handler = NumHandler(False)

    def increment(self, key, val):
        val = self.num_handler.parse(val)
        cur_aggr = self.stats.get(key)
        if cur_aggr is None:
            self.stats[key] = (val, 1)
        else:
            cur_sum, cur_cnt = cur_aggr
            self.stats[key] = (cur_sum + val, cur_cnt + 1)

    def get_final(self, key):
        final_sum, final_cnt = self.stats[key]
        return float(final_sum) / final_cnt


class VarianceAggregator:
    def __init__(self):
        self.stats = dict()
        self.num_handler = NumHandler(False)

    def increment(self, key, val):
        val = self.num_handler.parse(val)
        cur_aggr = self.stats.get(key)
        if cur_aggr is None:
            self.stats[key] = (val, val ** 2, 1)
        else:
            cur_sum, cur_sum_of_squares, cur_cnt = cur_aggr
            self.stats[key] = (cur_sum + val, cur_sum_of_squares + val ** 2, cur_cnt + 1)

    def get_final(self, key):
        final_sum, final_sum_of_squares, final_cnt = self.stats[key]
        return float(final_sum_of_squares) / final_cnt - (float(final_sum) / final_cnt) ** 2


class MedianAggregator:
    def __init__(self):
        self.stats = defaultdict(list)
        self.num_handler = NumHandler(True)

    def increment(self, key, val):
        val = self.num_handler.parse(val)
        self.stats[key].append(val)

    def get_final(self, key):
        sorted_vals = sorted(self.stats[key])
        assert len(sorted_vals)
        m = int(len(sorted_vals) / 2)
        if len(sorted_vals) % 2:
            return sorted_vals[m]
        else:
            a = sorted_vals[m - 1]
            b = sorted_vals[m]
            return a if a == b else (a + b) / 2.0


class CountAggregator:
    def __init__(self):
        self.stats = defaultdict(int)

    def increment(self, key, _val):
        self.stats[key] += 1

    def get_final(self, key):
        return self.stats[key]


class ArrayAggAggregator:
    def __init__(self, post_proc=None):
        self.stats = defaultdict(list)
        self.post_proc = post_proc

    def increment(self, key, val):
        self.stats[key].append(val)

    def get_final(self, key):
        res = self.stats[key]
        if self.post_proc is not None:
            return self.post_proc(res)
        return res


class ConstGroupVerifier:
    def __init__(self, output_index):
        self.const_values = dict()
        self.output_index = output_index

    def increment(self, key, value):
        old_value = self.const_values.get(key)
        if old_value is None:
            self.const_values[key] = value
        elif old_value != value:
            raise RbqlRuntimeError('Invalid aggregate expression: non-constant values in output column {}. E.g. "{}" and "{}"'.format(self.output_index + 1, old_value, value)) # UT JSON

    def get_final(self, key):
        return self.const_values[key]


def add_to_set(dst_set, value):
    len_before = len(dst_set)
    dst_set.add(value)
    return len_before != len(dst_set)


class TopWriter(object):
    def __init__(self, subwriter, top_count):
        self.subwriter = subwriter
        self.NW = 0
        self.top_count = top_count

    def write(self, record):
        if self.NW >= self.top_count:
            return False
        success = self.subwriter.write(record)
        if success:
            self.NW += 1
        return success

    def finish(self):
        self.subwriter.finish()


class UniqWriter(object):
    def __init__(self, subwriter):
        self.subwriter = subwriter
        self.seen = set()

    def write(self, record):
        immutable_record = tuple(record)
        if not add_to_set(self.seen, immutable_record):
            return True
        if not self.subwriter.write(record):
            return False
        return True

    def finish(self):
        self.subwriter.finish()


class UniqCountWriter(object):
    def __init__(self, subwriter):
        self.subwriter = subwriter
        self.records = OrderedDict()

    def write(self, record):
        record = tuple(record)
        if record in self.records:
            self.records[record] += 1
        else:
            self.records[record] = 1
        return True

    def finish(self):
        for record, cnt in iteritems6(self.records):
            mutable_record = list(record)
            mutable_record.insert(0, cnt)
            if not self.subwriter.write(mutable_record):
                break
        self.subwriter.finish()


class SortedWriter(object):
    def __init__(self, subwriter, reverse_sort):
        self.subwriter = subwriter
        self.reverse_sort = reverse_sort
        self.unsorted_entries = list()

    def write(self, sort_key_value, record):
        self.unsorted_entries.append((sort_key_value, record))
        return True

    def finish(self):
        sorted_entries = sorted(self.unsorted_entries, key=lambda x: x[0])
        if self.reverse_sort:
            sorted_entries.reverse()
        for e in sorted_entries:
            if not self.subwriter.write(e[1]):
                break
        self.subwriter.finish()


class AggregateWriter(object):
    def __init__(self, subwriter):
        self.subwriter = subwriter
        self.aggregators = []
        self.aggregation_keys = set()

    def finish(self):
        all_keys = sorted(list(self.aggregation_keys))
        for key in all_keys:
            out_fields = [ag.get_final(key) for ag in self.aggregators]
            if not self.subwriter.write(out_fields):
                break
        self.subwriter.finish()


class InnerJoiner(object):
    def __init__(self, join_map):
        self.join_map = join_map

    def get_rhs(self, lhs_key):
        return self.join_map.get_join_records(lhs_key)


class LeftJoiner(object):
    def __init__(self, join_map):
        self.join_map = join_map
        self.null_record = [(None, join_map.max_record_len, [None] * join_map.max_record_len)]

    def get_rhs(self, lhs_key):
        result = self.join_map.get_join_records(lhs_key)
        if len(result) == 0:
            return self.null_record
        return result


class StrictLeftJoiner(object):
    def __init__(self, join_map):
        self.join_map = join_map

    def get_rhs(self, lhs_key):
        result = self.join_map.get_join_records(lhs_key)
        if len(result) != 1:
            raise RbqlRuntimeError('In "{}" each key in A must have exactly one match in B. Bad A key: "{}"'.format(STRICT_LEFT_JOIN, lhs_key)) # UT JSON
        return result


def select_except(src, except_fields):
    result = list()
    for i, v in enumerate(src):
        if i not in except_fields:
            result.append(v)
    return result


def select_simple(query_context, sort_key, out_fields):
    if query_context.sort_key_expression is not None:
        if not query_context.writer.write(sort_key, out_fields):
            return False
    else:
        if not query_context.writer.write(out_fields):
            return False
    return True


def select_aggregated(query_context, key, transparent_values):
    if query_context.aggregation_stage == 1:
        if type(query_context.writer) is SortedWriter or type(query_context.writer) is UniqWriter or type(query_context.writer) is UniqCountWriter:
            raise RbqlParsingError(invalid_keyword_in_aggregate_query_error_msg) # UT JSON
        query_context.writer = AggregateWriter(query_context.writer)
        num_aggregators_found = 0
        for i, trans_value in enumerate(transparent_values):
            if isinstance(trans_value, RBQLAggregationToken):
                num_aggregators_found += 1
                query_context.writer.aggregators.append(query_context.functional_aggregators[trans_value.marker_id])
                query_context.writer.aggregators[-1].increment(key, trans_value.value)
            else:
                query_context.writer.aggregators.append(ConstGroupVerifier(len(query_context.writer.aggregators)))
                query_context.writer.aggregators[-1].increment(key, trans_value)
        if num_aggregators_found != len(query_context.functional_aggregators):
            raise RbqlParsingError(wrong_aggregation_usage_error) # UT JSON
        query_context.aggregation_stage = 2
    else:
        for i, trans_value in enumerate(transparent_values):
            query_context.writer.aggregators[i].increment(key, trans_value)
    query_context.writer.aggregation_keys.add(key)


PROCESS_SELECT_COMMON = '''
__RBQLMP__variables_init_code
if __RBQLMP__where_expression:
    out_fields = __RBQLMP__select_expression
    if query_context.aggregation_stage > 0:
        key = __RBQLMP__aggregation_key_expression
        select_aggregated(query_context, key, out_fields)
    else:
        sort_key = __RBQLMP__sort_key_expression
        if query_context.unnest_list is not None:
            if not select_unnested(sort_key, out_fields):
                stop_flag = True
        else:
            if not select_simple(query_context, sort_key, out_fields):
                stop_flag = True
'''


PROCESS_SELECT_SIMPLE = '''
star_fields = record_a
__CODE__
'''


PROCESS_SELECT_JOIN = '''
join_matches = query_context.join_map.get_rhs(__RBQLMP__lhs_join_var_expression)
for join_match in join_matches:
    bNR, bNF, record_b = join_match
    star_fields = record_a + record_b
    __CODE__
    if stop_flag:
        break
'''


PROCESS_UPDATE_JOIN = '''
join_matches = query_context.join_map.get_rhs(__RBQLMP__lhs_join_var_expression)
if len(join_matches) > 1:
    raise RbqlRuntimeError('More than one record in UPDATE query matched a key from the input table in the join table') # UT JSON # TODO output the failed key
if len(join_matches) == 1:
    bNR, bNF, record_b = join_matches[0]
else:
    bNR, bNF, record_b = None, None, None
up_fields = record_a[:]
__RBQLMP__variables_init_code
if len(join_matches) == 1 and (__RBQLMP__where_expression):
    NU += 1
    __RBQLMP__update_expressions
if not query_context.writer.write(up_fields):
    stop_flag = True
'''


PROCESS_UPDATE_SIMPLE = '''
up_fields = record_a[:]
__RBQLMP__variables_init_code
if __RBQLMP__where_expression:
    NU += 1
    __RBQLMP__update_expressions
if not query_context.writer.write(up_fields):
    stop_flag = True
'''

# We need dummy_wrapper_for_exec function because otherwise "import" statements won't work as expected if used inside user-defined functions, see: https://github.com/mechatroner/sublime_rainbow_csv/issues/22
MAIN_LOOP_BODY = '''
def dummy_wrapper_for_exec(query_context, user_namespace, LIKE, UNNEST, ANY_VALUE, MIN, MAX, COUNT, SUM, AVG, VARIANCE, MEDIAN, ARRAY_AGG, mad_max, mad_min, mad_sum, select_unnested):

    try:
        pass
        __USER_INIT_CODE__
    except Exception as e:
        raise RuntimeError('Exception while executing user-provided init code: {}'.format(e))

    like = LIKE
    unnest = UNNEST
    Unnest = UNNEST
    any_value = ANY_VALUE
    Any_value = ANY_VALUE
    Min = MIN
    Max = MAX
    count = COUNT
    Count = COUNT
    Sum = SUM
    avg = AVG
    Avg = AVG
    variance = VARIANCE
    Variance = VARIANCE
    median = MEDIAN
    Median = MEDIAN
    array_agg = ARRAY_AGG
    max = mad_max
    min = mad_min
    sum = mad_sum

    udf = user_namespace

    NR = 0
    NU = 0
    stop_flag = False

    while not stop_flag:
        record_a = query_context.input_iterator.get_record()
        if record_a is None:
            break
        NR += 1
        NF = len(record_a)
        query_context.unnest_list = None # TODO optimize, don't need to set this every iteration
        try:
            __CODE__
        except InternalBadKeyError as e:
            raise RbqlRuntimeError('No "{}" field at record {}'.format(e.bad_key, NR)) # UT JSON
        except InternalBadFieldError as e:
            raise RbqlRuntimeError('No "a{}" field at record {}'.format(e.bad_idx + 1, NR)) # UT JSON
        except RbqlParsingError:
            raise
        except Exception as e:
            if debug_mode:
                raise
            if str(e).find('RBQLAggregationToken') != -1:
                raise RbqlParsingError(wrong_aggregation_usage_error) # UT JSON
            raise RbqlRuntimeError('At record ' + str(NR) + ', Details: ' + str(e)) # UT JSON

dummy_wrapper_for_exec(query_context, user_namespace, LIKE, UNNEST, ANY_VALUE, MIN, MAX, COUNT, SUM, AVG, VARIANCE, MEDIAN, ARRAY_AGG, mad_max, mad_min, mad_sum, select_unnested)
'''


def embed_expression(parent_code, child_placeholder, child_expression):
    assert parent_code.count(child_placeholder) == 1
    assert child_expression.find('\n') == -1
    return parent_code.strip().replace(child_placeholder, child_expression) + '\n'


def embed_code(parent_code, child_placeholder, child_code):
    assert parent_code.count(child_placeholder) == 1
    parent_lines = parent_code.strip().split('\n')
    child_lines = child_code.strip().split('\n')
    for i in range(len(parent_lines)):
        pos = parent_lines[i].find(child_placeholder)
        if pos == -1:
            continue
        assert pos % 4 == 0
        placeholder_indentation = parent_lines[i][:pos]
        assert placeholder_indentation == ' ' * pos
        child_lines = [placeholder_indentation + cl for cl in child_lines]
        result_lines = parent_lines[:i] + child_lines + parent_lines[i + 1:]
        return '\n'.join(result_lines) + '\n'
    assert False


def generate_main_loop_code(query_context):
    is_select_query = query_context.select_expression is not None
    is_join_query = query_context.join_map is not None
    where_expression = 'True' if query_context.where_expression is None else query_context.where_expression
    aggregation_key_expression = 'None' if query_context.aggregation_key_expression is None else query_context.aggregation_key_expression
    sort_key_expression = 'None' if query_context.sort_key_expression is None else query_context.sort_key_expression
    python_code = embed_code(MAIN_LOOP_BODY, '__USER_INIT_CODE__', query_context.user_init_code)
    if is_select_query:
        if is_join_query:
            python_code = embed_code(embed_code(python_code, '__CODE__', PROCESS_SELECT_JOIN), '__CODE__', PROCESS_SELECT_COMMON)
            python_code = embed_expression(python_code, '__RBQLMP__lhs_join_var_expression', query_context.lhs_join_var_expression)
        else:
            python_code = embed_code(embed_code(python_code, '__CODE__', PROCESS_SELECT_SIMPLE), '__CODE__', PROCESS_SELECT_COMMON)
        python_code = embed_code(python_code, '__RBQLMP__variables_init_code', query_context.variables_init_code)
        python_code = embed_expression(python_code, '__RBQLMP__select_expression', query_context.select_expression)
        python_code = embed_expression(python_code, '__RBQLMP__where_expression', where_expression)
        python_code = embed_expression(python_code, '__RBQLMP__aggregation_key_expression', aggregation_key_expression)
        python_code = embed_expression(python_code, '__RBQLMP__sort_key_expression', sort_key_expression)
    else:
        if is_join_query:
            python_code = embed_code(python_code, '__CODE__', PROCESS_UPDATE_JOIN)
            python_code = embed_expression(python_code, '__RBQLMP__lhs_join_var_expression', query_context.lhs_join_var_expression)
        else:
            python_code = embed_code(python_code, '__CODE__', PROCESS_UPDATE_SIMPLE)
        python_code = embed_code(python_code, '__RBQLMP__variables_init_code', query_context.variables_init_code)
        python_code = embed_code(python_code, '__RBQLMP__update_expressions', query_context.update_expressions)
        python_code = embed_expression(python_code, '__RBQLMP__where_expression', where_expression)
    return python_code


builtin_max = max
builtin_min = min
builtin_sum = sum


def compile_and_run(query_context, user_namespace, unit_test_mode=False):
    def LIKE(text, pattern):
        matcher = query_context.like_regex_cache.get(pattern, None)
        if matcher is None:
            matcher = re.compile(like_to_regex(pattern))
            query_context.like_regex_cache[pattern] = matcher
        return matcher.match(text) is not None

    class UNNEST:
        def __init__(self, vals):
            if query_context.unnest_list is not None:
                # Technically we can support multiple UNNEST's but the implementation/algorithm is more complex and just doesn't worth it
                raise RbqlParsingError('Only one UNNEST is allowed per query') # UT JSON
            query_context.unnest_list = vals

        def __str__(self):
            raise TypeError('UNNEST')

    def select_unnested(sort_key, folded_fields):
        unnest_pos = None
        for i, trans_value in enumerate(folded_fields):
            if isinstance(trans_value, UNNEST):
                unnest_pos = i
                break
        assert unnest_pos is not None
        for v in query_context.unnest_list:
            out_fields = folded_fields[:]
            out_fields[unnest_pos] = v
            if not select_simple(query_context, sort_key, out_fields):
                return False
        return True

    def init_aggregator(generator_name, val, post_proc=None):
        query_context.aggregation_stage = 1
        res = RBQLAggregationToken(len(query_context.functional_aggregators), val)
        if post_proc is not None:
            query_context.functional_aggregators.append(generator_name(post_proc))
        else:
            query_context.functional_aggregators.append(generator_name())
        return res


    def ANY_VALUE(val):
        return init_aggregator(AnyValueAggregator, val) if query_context.aggregation_stage < 2 else val

    def MIN(val):
        return init_aggregator(MinAggregator, val) if query_context.aggregation_stage < 2 else val

    def MAX(val):
        return init_aggregator(MaxAggregator, val) if query_context.aggregation_stage < 2 else val

    def COUNT(_val):
        return init_aggregator(CountAggregator, 1) if query_context.aggregation_stage < 2 else 1

    def SUM(val):
        return init_aggregator(SumAggregator, val) if query_context.aggregation_stage < 2 else val

    def AVG(val):
        return init_aggregator(AvgAggregator, val) if query_context.aggregation_stage < 2 else val

    def VARIANCE(val):
        return init_aggregator(VarianceAggregator, val) if query_context.aggregation_stage < 2 else val

    def MEDIAN(val):
        return init_aggregator(MedianAggregator, val) if query_context.aggregation_stage < 2 else val

    def ARRAY_AGG(val, post_proc=None):
        # TODO consider passing array to output writer
        return init_aggregator(ArrayAggAggregator, val, post_proc) if query_context.aggregation_stage < 2 else val


    # We use `mad_` prefix with the function names to avoid ovewriting global min/max/sum just yet - this might interfere with logic inside user-defined functions in the init code.
    def mad_max(*args, **kwargs):
        single_arg = len(args) == 1 and not kwargs
        if single_arg:
            if PY3 and isinstance(args[0], str):
                return MAX(args[0])
            if not PY3 and isinstance(args[0], basestring):
                return MAX(args[0])
            if isinstance(args[0], int) or isinstance(args[0], float):
                return MAX(args[0])
        try:
            return max(*args, **kwargs)
        except TypeError:
            if single_arg:
                return MAX(args[0])
            raise


    def mad_min(*args, **kwargs):
        single_arg = len(args) == 1 and not kwargs
        if single_arg:
            if PY3 and isinstance(args[0], str):
                return MIN(args[0])
            if not PY3 and isinstance(args[0], basestring):
                return MIN(args[0])
            if isinstance(args[0], int) or isinstance(args[0], float):
                return MIN(args[0])
        try:
            return min(*args, **kwargs)
        except TypeError:
            if single_arg:
                return MIN(args[0])
            raise


    def mad_sum(*args):
        try:
            return sum(*args)
        except TypeError:
            if len(args) == 1:
                return SUM(args[0])
            raise

    if unit_test_mode:
        # Return these 3 functions to be able to unit test them from outside
        return (mad_max, mad_min, mad_sum)

    main_loop_body = generate_main_loop_code(query_context)
    compiled_main_loop = compile(main_loop_body, '<main loop>', 'exec')
    exec(compiled_main_loop, globals(), locals())


def exception_to_error_info(e):
    exceptions_type_map = {
        'RbqlRuntimeError': 'query execution',
        'RbqlParsingError': 'query parsing',
        'RbqlIOHandlingError': 'IO handling'
    }
    if isinstance(e, SyntaxError):
        import traceback
        etype, evalue, _etb = sys.exc_info()
        error_strings = traceback.format_exception_only(etype, evalue)
        if len(error_strings) and re.search('File.*line', error_strings[0]) is not None:
            error_strings[0] = '\n'
        error_msg = ''.join(error_strings).rstrip()
        if re.search(' having ', error_msg, flags=re.IGNORECASE) is not None:
            error_msg += "\nRBQL doesn't support \"HAVING\" keyword"
        if re.search(' like[ (]', error_msg, flags=re.IGNORECASE) is not None:
            error_msg += "\nRBQL doesn't support \"LIKE\" operator, use like() function instead e.g. ... WHERE like(a1, 'foo%bar') ... " # UT JSON
        if error_msg.lower().find(' from ') != -1:
            error_msg += "\nTip: If input table is defined by the environment, RBQL query should not have \"FROM\" keyword" # UT JSON
        return ('syntax error', error_msg)
    error_type = 'unexpected'
    error_msg = str(e)
    for k, v in exceptions_type_map.items():
        if type(e).__name__.find(k) != -1:
            error_type = v
    return (error_type, error_msg)


def strip_comments(cline):
    cline = cline.strip()
    if cline.startswith('#'):
        return ''
    return cline


def combine_string_literals(backend_expression, string_literals):
    for i in range(len(string_literals)):
        backend_expression = backend_expression.replace('___RBQL_STRING_LITERAL{}___'.format(i), string_literals[i])
    return backend_expression


def parse_join_expression(src):
    src = src.strip()
    invalid_join_syntax_error = 'Invalid join syntax. Valid syntax: <JOIN> /path/to/B/table on a... == b... [and a... == b... [and ... ]]'
    match = re.search(r'^([^ ]+) +on +', src, re.IGNORECASE)
    if match is None:
        raise RbqlParsingError(invalid_join_syntax_error)
    table_id = match.group(1)
    src = src[match.end():]
    variable_pairs = []
    while True:
        match = re.search('^([^ =]+) *==? *([^ =]+)', src)
        if match is None:
            raise RbqlParsingError(invalid_join_syntax_error)
        variable_pair = (match.group(1), match.group(2))
        variable_pairs.append(variable_pair)
        src = src[match.end():]
        if not len(src):
            break
        match = re.search('^ +and +', src, re.IGNORECASE)
        if match is None:
            raise RbqlParsingError(invalid_join_syntax_error)
        src = src[match.end():]
    return (table_id, variable_pairs)


def resolve_join_variables(input_variables_map, join_variables_map, variable_pairs, string_literals):
    lhs_variables = []
    rhs_indices = []
    valid_join_syntax_msg = 'Valid JOIN syntax: <JOIN> /path/to/B/table on a... == b... [and a... == b... [and ... ]]'
    for join_var_1, join_var_2 in variable_pairs:
        join_var_1 = combine_string_literals(join_var_1, string_literals)
        join_var_2 = combine_string_literals(join_var_2, string_literals)
        if join_var_1 in input_variables_map and join_var_1 in join_variables_map:
            raise RbqlParsingError(ambiguous_error_msg.format(join_var_1))
        if join_var_2 in input_variables_map and join_var_2 in join_variables_map:
            raise RbqlParsingError(ambiguous_error_msg.format(join_var_2))
        if join_var_2 in input_variables_map:
            join_var_1, join_var_2 = join_var_2, join_var_1
        if join_var_1 in ['NR', 'a.NR', 'aNR']:
            lhs_key_index = -1
        elif join_var_1 in input_variables_map:
            lhs_key_index = input_variables_map.get(join_var_1).index
        else:
            raise RbqlParsingError('Unable to parse JOIN expression: Input table does not have field "{}"\n{}'.format(join_var_1, valid_join_syntax_msg)) # UT JSON
        if join_var_2 in ['bNR', 'b.NR']:
            rhs_key_index = -1
        elif join_var_2 in join_variables_map:
            rhs_key_index = join_variables_map.get(join_var_2).index
        else:
            raise RbqlParsingError('Unable to parse JOIN expression: Join table does not have field "{}"\n{}'.format(join_var_2, valid_join_syntax_msg)) # UT JSON
        lhs_join_var_expression = 'NR' if lhs_key_index == -1 else 'safe_join_get(record_a, {})'.format(lhs_key_index)
        rhs_indices.append(rhs_key_index)
        lhs_variables.append(lhs_join_var_expression)
    return (lhs_variables, rhs_indices)


def parse_basic_variables(query_text, prefix, dst_variables_map):
    assert prefix in ['a', 'b']
    rgx = '(?:^|[^_a-zA-Z0-9]){}([1-9][0-9]*)(?:$|(?=[^_a-zA-Z0-9]))'.format(prefix)
    matches = list(re.finditer(rgx, query_text))
    field_nums = list(set([int(m.group(1)) for m in matches]))
    for field_num in field_nums:
        dst_variables_map[prefix + str(field_num)] = VariableInfo(initialize=True, index=field_num - 1)


def parse_array_variables(query_text, prefix, dst_variables_map):
    assert prefix in ['a', 'b']
    rgx = r'(?:^|[^_a-zA-Z0-9]){}\[([1-9][0-9]*)\]'.format(prefix)
    matches = list(re.finditer(rgx, query_text))
    field_nums = list(set([int(m.group(1)) for m in matches]))
    for field_num in field_nums:
        dst_variables_map['{}[{}]'.format(prefix, field_num)] = VariableInfo(initialize=True, index=field_num - 1)


def python_string_escape_column_name(column_name, quote_char):
    assert quote_char in ['"', "'"]
    column_name = column_name.replace('\\', '\\\\')
    column_name = column_name.replace('\n', '\\n')
    column_name = column_name.replace('\r', '\\r')
    column_name = column_name.replace('\t', '\\t')
    if quote_char == '"':
        return column_name.replace('"', '\\"')
    return column_name.replace("'", "\\'")


def query_probably_has_dictionary_variable(query_text, column_name):
    # It is OK to return false positive - in the worst case we woud just waste some performance on unused variable initialization
    continuous_name_segments = re.findall('[-a-zA-Z0-9_:;+=!.,()%^#@&* ]+', column_name)
    for continuous_segment in continuous_name_segments:
        if query_text.find(continuous_segment) == -1:
            return False
    return True


def parse_dictionary_variables(query_text, prefix, column_names, dst_variables_map):
    # The purpose of this algorithm is to minimize number of variables in varibale_map to improve performance, ideally it should be only variables from the query
    # TODO implement algorithm for honest python f-string parsing
    assert prefix in ['a', 'b']
    if re.search(r'(?:^|[^_a-zA-Z0-9]){}\['.format(prefix), query_text) is None:
        return
    for i in range(len(column_names)):
        column_name = column_names[i]
        if query_probably_has_dictionary_variable(query_text, column_name):
            dst_variables_map['{}["{}"]'.format(prefix, python_string_escape_column_name(column_name, '"'))] = VariableInfo(initialize=True, index=i)
            dst_variables_map["{}['{}']".format(prefix, python_string_escape_column_name(column_name, "'"))] = VariableInfo(initialize=False, index=i)


def parse_attribute_variables(query_text, prefix, column_names, column_names_source, dst_variables_map):
    # The purpose of this algorithm is to minimize number of variables in varibale_map to improve performance, ideally it should be only variables from the query

    # TODO ideally we should either:
    # * not search inside string literals (excluding brackets in f-strings) OR
    # * check if column_name is not among reserved python keywords like "None", "if", "else", etc
    assert prefix in ['a', 'b']
    column_names = {v: i for i, v in enumerate(column_names)}
    rgx = r'(?:^|[^_a-zA-Z0-9]){}\.([_a-zA-Z][_a-zA-Z0-9]*)'.format(prefix)
    matches = list(re.finditer(rgx, query_text))
    column_names_from_query = list(set([m.group(1) for m in matches]))
    for column_name in column_names_from_query:
        zero_based_idx = column_names.get(column_name)
        if zero_based_idx is not None:
            dst_variables_map['{}.{}'.format(prefix, column_name)] = VariableInfo(initialize=True, index=zero_based_idx)
        else:
            raise RbqlParsingError('Unable to find column "{}" in {} {}'.format(column_name, {'a': 'input', 'b': 'join'}[prefix], column_names_source))


def map_variables_directly(query_text, column_names, dst_variables_map):
    for idx, column_name in enumerate(column_names):
        if re.match(r'^[_a-zA-Z][_a-zA-Z0-9]*$', column_name) is None:
            raise RbqlIOHandlingError('Unable to use column name "{}" as RBQL/Python variable'.format(column_name))
        if query_text.find(column_name) != -1:
            dst_variables_map[column_name] = VariableInfo(initialize=True, index=idx)


def ensure_no_ambiguous_variables(query_text, input_column_names, join_column_names):
    join_column_names_set = set(join_column_names)
    for column_name in input_column_names:
        if column_name in join_column_names_set and query_text.find(column_name) != -1: # False positive is tolerable here
            raise RbqlParsingError(ambiguous_error_msg.format(column_name))



def generate_common_init_code(query_text, variable_prefix):
    assert variable_prefix in ['a', 'b']
    result = list()
    # TODO [PERFORMANCE] do not initialize RBQLRecord if we don't have `a.` or `a[` prefix in the query
    result.append('{} = RBQLRecord()'.format(variable_prefix))
    base_var = 'NR' if variable_prefix == 'a' else 'bNR'
    attr_var = '{}.NR'.format(variable_prefix)
    if query_text.find(attr_var) != -1:
        result.append('{} = {}'.format(attr_var, base_var))
    if variable_prefix == 'a' and query_text.find('aNR') != -1:
        result.append('aNR = NR')
    return result


def generate_init_statements(query_text, variables_map, join_variables_map):
    code_lines = generate_common_init_code(query_text, 'a')
    for var_name, var_info in variables_map.items():
        if var_info.initialize:
            code_lines.append('{} = safe_get(record_a, {})'.format(var_name, var_info.index))
    if join_variables_map:
        code_lines += generate_common_init_code(query_text, 'b')
        for var_name, var_info in join_variables_map.items():
            if var_info.initialize:
                code_lines.append('{} = safe_get(record_b, {}) if record_b is not None else None'.format(var_name, var_info.index))
    return '\n'.join(code_lines)


def replace_star_count(aggregate_expression):
    return re.sub(r'(?:(?<=^)|(?<=,)) *COUNT\( *\* *\)', ' COUNT(1)', aggregate_expression, flags=re.IGNORECASE).lstrip(' ')


def replace_star_vars(rbql_expression):
    star_matches = list(re.finditer(r'(?:^|,) *(\*|a\.\*|b\.\*) *(?=$|,)', rbql_expression))
    last_pos = 0
    result = ''
    for match in star_matches:
        star_expression = match.group(1)
        replacement_expression = '] + ' + {'*': 'star_fields', 'a.*': 'record_a', 'b.*': 'record_b'}[star_expression] + ' + ['
        if last_pos < match.start():
            result += rbql_expression[last_pos:match.start()]
        result += replacement_expression
        last_pos = match.end() + 1 # Adding one to skip the lookahead comma
    result += rbql_expression[last_pos:]
    return result


def replace_star_vars_for_ast(rbql_expression):
    star_matches = list(re.finditer(r'(?:(?<=^)|(?<=,)) *(\*|a\.\*|b\.\*) *(?=$|,)', rbql_expression))
    last_pos = 0
    result = ''
    for match in star_matches:
        star_expression = match.group(1)
        replacement_expression = {'*': '__RBQL_INTERNAL_STAR', 'a.*': 'a.__RBQL_INTERNAL_STAR', 'b.*': 'b.__RBQL_INTERNAL_STAR'}[star_expression]
        if last_pos < match.start():
            result += rbql_expression[last_pos:match.start()]
        result += replacement_expression
        last_pos = match.end()
    result += rbql_expression[last_pos:]
    return result


def translate_update_expression(update_expression, input_variables_map, string_literals):
    assignment_looking_rgx = re.compile(r'(?:^|,) *(a[.#a-zA-Z0-9\[\]_]*) *=(?=[^=])')
    update_expressions = []
    pos = 0
    first_assignment_error = 'Unable to parse "UPDATE" expression: the expression must start with assignment, but "{}" does not look like an assignable field name'.format(update_expression.split('=')[0].strip())
    while True:
        match = assignment_looking_rgx.search(update_expression, pos)
        if not len(update_expressions) and (match is None or match.start() != 0):
            raise RbqlParsingError(first_assignment_error) # UT JSON
        if match is None:
            update_expressions[-1] += update_expression[pos:].strip() + ')'
            break
        if len(update_expressions):
            update_expressions[-1] += update_expression[pos:match.start()].strip() + ')'
        dst_var_name = combine_string_literals(match.group(1).strip(), string_literals)
        var_info = input_variables_map.get(dst_var_name)
        if var_info is None:
            raise RbqlParsingError('Unable to parse "UPDATE" expression: Unknown field name: "{}"'.format(dst_var_name)) # UT JSON
        update_expressions.append('safe_set(up_fields, {}, '.format(var_info.index))
        pos = match.end()
    return combine_string_literals('\n'.join(update_expressions), string_literals)


def translate_select_expression(select_expression):
    regexp_for_as_column_alias = r' +(AS|as) +([a-zA-Z][a-zA-Z0-9_]*) *(?=$|,)'
    expression_without_counting_stars = replace_star_count(select_expression)

    # TODO the problem with these replaments is that they happen on global level, the right way to do this is to split the query into columns first by using stack-parsing.
    # Or we can at least replace parentheses groups with literals e.g. `(.....)` -> `(PARENT_GROUP_1)`

    expression_without_as_column_alias = re.sub(regexp_for_as_column_alias, '', expression_without_counting_stars).strip()
    translated = replace_star_vars(expression_without_as_column_alias).strip()

    expression_without_as_column_alias_for_ast = re.sub(regexp_for_as_column_alias, r' == alias_column_as_pseudo_func(\2)', expression_without_counting_stars).strip()
    # Replace `as xyz` with `== alias_column_as_pseudo_func(xyz)` as a workaround to make it parsable to Python ast.
    translated_for_ast = replace_star_vars_for_ast(expression_without_as_column_alias_for_ast).strip()

    if not len(translated):
        raise RbqlParsingError('"SELECT" expression is empty') # UT JSON
    return ('[{}]'.format(translated), translated_for_ast)


def separate_string_literals(rbql_expression):
    # The regex is improved expression from here: https://stackoverflow.com/a/14366904/2898283
    string_literals_regex = r'''(\"\"\"|\'\'\'|\"|\')((?<!\\)(\\\\)*\\\1|.)*?\1'''
    matches = list(re.finditer(string_literals_regex, rbql_expression))
    string_literals = list()
    format_parts = list()
    idx_before = 0
    for m in matches:
        literal_id = len(string_literals)
        string_literals.append(m.group(0))
        format_parts.append(rbql_expression[idx_before:m.start()])
        format_parts.append('___RBQL_STRING_LITERAL{}___'.format(literal_id))
        idx_before = m.end()
    format_parts.append(rbql_expression[idx_before:])
    format_expression = ''.join(format_parts)
    format_expression = format_expression.replace('\t', ' ')
    return (format_expression, string_literals)


def locate_statements(statement_groups, rbql_expression):
    result = list()
    for st_group in statement_groups:
        for statement in st_group:
            rgxp = r'(?i)(?:^| ){}(?= )'.format(statement.replace(' ', ' *'))
            matches = list(re.finditer(rgxp, rbql_expression))
            if not len(matches):
                continue
            if len(matches) > 1:
                raise RbqlParsingError('More than one "{}" statements found'.format(statement)) # UT JSON
            assert len(matches) == 1
            match = matches[0]
            result.append((match.start(), match.end(), statement))
            break # Break to avoid matching a sub-statement from the same group e.g. "INNER JOIN" -> "JOIN"
    return sorted(result)


def separate_actions(statement_groups, rbql_expression):
    # TODO add more checks:
    # make sure all rbql_expression was separated and SELECT or UPDATE is at the beginning
    rbql_expression = rbql_expression.strip(' ')
    result = dict()
    # For now support no more than one query modifier per query
    mobj = re.match('^(.*)  *[Ww][Ii][Tt][Hh] *\(([a-z]{4,20})\) *$', rbql_expression)
    if mobj is not None:
        rbql_expression = mobj.group(1)
        result[WITH] = mobj.group(2)
    ordered_statements = locate_statements(statement_groups, rbql_expression)
    for i in range(len(ordered_statements)):
        statement_start = ordered_statements[i][0]
        span_start = ordered_statements[i][1]
        statement = ordered_statements[i][2]
        span_end = ordered_statements[i + 1][0] if i + 1 < len(ordered_statements) else len(rbql_expression)
        assert statement_start < span_start
        assert span_start <= span_end
        span = rbql_expression[span_start:span_end]

        statement_params = dict()

        if statement in [STRICT_LEFT_JOIN, LEFT_OUTER_JOIN, LEFT_JOIN, INNER_JOIN, JOIN]:
            statement_params['join_subtype'] = statement
            statement = JOIN

        if statement == UPDATE:
            if statement_start != 0:
                raise RbqlParsingError('UPDATE keyword must be at the beginning of the query') # UT JSON
            span = re.sub('(?i)^ *SET ', '', span)

        if statement == ORDER_BY:
            span = re.sub('(?i) ASC *$', '', span)
            new_span = re.sub('(?i) DESC *$', '', span)
            if new_span != span:
                span = new_span
                statement_params['reverse'] = True
            else:
                statement_params['reverse'] = False

        if statement == SELECT:
            if statement_start != 0:
                raise RbqlParsingError('SELECT keyword must be at the beginning of the query') # UT JSON
            match = re.match('(?i)^ *TOP *([0-9]+) ', span)
            if match is not None:
                statement_params['top'] = int(match.group(1))
                span = span[match.end():]
            match = re.match('(?i)^ *DISTINCT *(COUNT)? ', span)
            if match is not None:
                statement_params['distinct'] = True
                if match.group(1) is not None:
                    statement_params['distinct_count'] = True
                span = span[match.end():]

        statement_params['text'] = span.strip()
        result[statement] = statement_params
    if SELECT not in result and UPDATE not in result:
        raise RbqlParsingError('Query must contain either SELECT or UPDATE statement') # UT JSON
    if SELECT in result and UPDATE in result:
        raise RbqlParsingError('Query can not contain both SELECT and UPDATE statements')
    return result


def find_top(rb_actions):
    if LIMIT in rb_actions:
        try:
            return int(rb_actions[LIMIT]['text'])
        except ValueError:
            raise RbqlParsingError('LIMIT keyword must be followed by an integer') # UT JSON
    return rb_actions[SELECT].get('top', None)


def translate_except_expression(except_expression, input_variables_map, string_literals, input_header):
    skip_vars = except_expression.split(',')
    skip_vars = [v.strip() for v in skip_vars]
    skip_indices = list()
    for var_name in skip_vars:
        var_name = combine_string_literals(var_name, string_literals)
        var_info = input_variables_map.get(var_name)
        if var_info is None:
            raise RbqlParsingError('Unknown field in EXCEPT expression: "{}"'.format(var_name)) # UT JSON
        skip_indices.append(var_info.index)
    skip_indices = sorted(skip_indices)
    output_header = None if input_header is None else select_except(input_header, skip_indices)
    skip_indices = [str(v) for v in skip_indices]
    return (output_header, 'select_except(record_a, [{}])'.format(','.join(skip_indices)))


class HashJoinMap:
    # Other possible flavors: BinarySearchJoinMap, MergeJoinMap
    def __init__(self, record_iterator, key_indices):
        self.max_record_len = 0
        self.hash_map = defaultdict(list)
        self.record_iterator = record_iterator
        self.key_indices = None
        self.key_index = None
        if len(key_indices) == 1:
            self.key_index = key_indices[0]
            self.polymorphic_get_key = self.get_single_key
        else:
            self.key_indices = key_indices
            self.polymorphic_get_key = self.get_multi_key


    def get_single_key(self, nr, fields):
        if self.key_index >= len(fields):
            raise RbqlRuntimeError('No field with index {} at record {} in "B" table'.format(self.key_index + 1, nr))
        return nr if self.key_index == -1 else fields[self.key_index]


    def get_multi_key(self, nr, fields):
        result = []
        for ki in self.key_indices:
            if ki >= len(fields):
                raise RbqlRuntimeError('No field with index {} at record {} in "B" table'.format(ki + 1, nr))
            result.append(nr if ki == -1 else fields[ki])
        return tuple(result)


    def build(self):
        nr = 0
        while True:
            fields = self.record_iterator.get_record()
            if fields is None:
                break
            nr += 1
            nf = len(fields)
            self.max_record_len = max(self.max_record_len, nf)
            key = self.polymorphic_get_key(nr, fields)
            self.hash_map[key].append((nr, nf, fields))


    def get_join_records(self, key):
        return self.hash_map[key]


    def get_warnings(self):
        return self.record_iterator.get_warnings()


def cleanup_query(query_text):
    rbql_lines = query_text.split('\n')
    rbql_lines = [strip_comments(l) for l in rbql_lines]
    rbql_lines = [l for l in rbql_lines if len(l)]
    return ' '.join(rbql_lines).rstrip(';')


def remove_redundant_input_table_name(query_text):
    query_text = re.sub(' +from +a(?: +|$)', ' ', query_text, flags=re.IGNORECASE).strip()
    query_text = re.sub('^ *update +a +set ', 'update ', query_text, flags=re.IGNORECASE).strip()
    return query_text


def select_output_header(input_header, join_header, query_column_infos):
    if input_header is None:
        assert join_header is None
    query_has_star = False
    query_has_column_alias = False
    for qci in query_column_infos:
        query_has_star = query_has_star or (qci is not None and qci.is_star)
        query_has_column_alias = query_has_column_alias or (qci is not None and qci.alias_name is not None)

    if input_header is None:
        if query_has_star and query_has_column_alias:
            raise RbqlParsingError('Using both * (star) and AS alias in the same query is not allowed for input tables without header')
        if not query_has_column_alias:
            return None
        input_header = []
        join_header = []
    if join_header is None:
        # This means that there is no join table.
        join_header = []
    output_header = []
    for qci in query_column_infos:
        if qci is None:
            output_header.append('col{}'.format(len(output_header) + 1))
        elif qci.is_star:
            if qci.table_name is None:
                output_header += input_header + join_header
            elif qci.table_name == 'a':
                output_header += input_header
            elif qci.table_name == 'b':
                output_header += join_header
        elif qci.column_name is not None:
            output_header.append(qci.column_name)
        elif qci.alias_name is not None:
            output_header.append(qci.alias_name)
        elif qci.column_index is not None:
            if qci.table_name == 'a' and qci.column_index < len(input_header):
                output_header.append(input_header[qci.column_index])
            elif qci.table_name == 'b' and qci.column_index < len(join_header):
                output_header.append(join_header[qci.column_index])
            else:
                output_header.append('col{}'.format(len(output_header) + 1))
        else: # Should never happen
            output_header.append('col{}'.format(len(output_header) + 1))
    return output_header


def shallow_parse_input_query(query_text, input_iterator, tables_registry, query_context):
    query_text = cleanup_query(query_text)
    format_expression, string_literals = separate_string_literals(query_text)
    statement_groups = default_statement_groups[:]
    if input_iterator is not None:
        # In case if input_iterator i.e. input table is already fixed RBQL assumes that the only valid table name is "A" or "a".
        format_expression = remove_redundant_input_table_name(format_expression)
        statement_groups.remove([FROM])
    else:
        assert tables_registry is not None
    rb_actions = separate_actions(statement_groups, format_expression)

    if FROM in rb_actions:
        assert input_iterator is None
        input_table_id = rb_actions[FROM]['text']
        input_iterator = tables_registry.get_iterator_by_table_id(input_table_id, 'a')
        if input_iterator is None:
            raise RbqlParsingError('Unable to find input table: "{}"'.format(input_table_id))
        query_context.input_iterator = input_iterator

    if input_iterator is None:
        raise RbqlParsingError('Queries without context-based input table must contain "FROM" statement')

    if WITH in rb_actions:
        input_iterator.handle_query_modifier(rb_actions[WITH])
    input_variables_map = input_iterator.get_variables_map(query_text)

    if ORDER_BY in rb_actions and UPDATE in rb_actions:
        raise RbqlParsingError('"ORDER BY" is not allowed in "UPDATE" queries') # UT JSON

    if GROUP_BY in rb_actions:
        if ORDER_BY in rb_actions or UPDATE in rb_actions:
            raise RbqlParsingError(invalid_keyword_in_aggregate_query_error_msg) # UT JSON
        query_context.aggregation_key_expression = '({},)'.format(combine_string_literals(rb_actions[GROUP_BY]['text'], string_literals))
        query_context.aggregation_stage = 1


    input_header = input_iterator.get_header()
    join_variables_map = None
    join_header = None
    if JOIN in rb_actions:
        rhs_table_id, variable_pairs = parse_join_expression(rb_actions[JOIN]['text'])
        if tables_registry is None:
            raise RbqlParsingError('JOIN operations are not supported by the application') # UT JSON
        join_record_iterator = tables_registry.get_iterator_by_table_id(rhs_table_id, 'b')
        if join_record_iterator is None:
            raise RbqlParsingError('Unable to find join table: "{}"'.format(rhs_table_id)) # UT JSON CSV
        if WITH in rb_actions:
            join_record_iterator.handle_query_modifier(rb_actions[WITH])
        join_variables_map = join_record_iterator.get_variables_map(query_text)
        join_header = join_record_iterator.get_header()
        if input_header is None and join_header is not None:
            raise RbqlIOHandlingError('Inconsistent modes: Input table doesn\'t have a header while the Join table has a header')
        if input_header is not None and join_header is None:
            raise RbqlIOHandlingError('Inconsistent modes: Input table has a header while the Join table doesn\'t have a header')

        # TODO check ambiguous column names here instead of external check.
        lhs_variables, rhs_indices = resolve_join_variables(input_variables_map, join_variables_map, variable_pairs, string_literals)
        joiner_type = {JOIN: InnerJoiner, INNER_JOIN: InnerJoiner, LEFT_OUTER_JOIN: LeftJoiner, LEFT_JOIN: LeftJoiner, STRICT_LEFT_JOIN: StrictLeftJoiner}[rb_actions[JOIN]['join_subtype']]
        query_context.lhs_join_var_expression = lhs_variables[0] if len(lhs_variables) == 1 else '({})'.format(', '.join(lhs_variables))
        query_context.join_map_impl = HashJoinMap(join_record_iterator, rhs_indices)
        query_context.join_map_impl.build()
        query_context.join_map = joiner_type(query_context.join_map_impl)

    query_context.variables_init_code = combine_string_literals(generate_init_statements(format_expression, input_variables_map, join_variables_map), string_literals)


    if WHERE in rb_actions:
        where_expression = rb_actions[WHERE]['text']
        if re.search(r'[^><!=]=[^=]', where_expression) is not None:
            raise RbqlParsingError('Assignments "=" are not allowed in "WHERE" expressions. For equality test use "=="') # UT JSON
        query_context.where_expression = combine_string_literals(where_expression, string_literals)


    if UPDATE in rb_actions:
        update_expression = translate_update_expression(rb_actions[UPDATE]['text'], input_variables_map, string_literals)
        query_context.update_expressions = combine_string_literals(update_expression, string_literals)
        query_context.writer.set_header(input_header)


    if SELECT in rb_actions:
        query_context.top_count = find_top(rb_actions)

        if EXCEPT in rb_actions:
            if JOIN in rb_actions:
                raise RbqlParsingError('EXCEPT and JOIN are not allowed in the same query') # UT JSON
            output_header, select_expression = translate_except_expression(rb_actions[EXCEPT]['text'], input_variables_map, string_literals, input_header)
        else:
            select_expression, select_expression_for_ast = translate_select_expression(rb_actions[SELECT]['text'])
            select_expression = combine_string_literals(select_expression, string_literals)
            # We need to add string literals back in order to have relevant errors in case of exceptions during parsing
            combined_select_expression_for_ast = combine_string_literals(select_expression_for_ast, string_literals)
            column_infos = ast_parse_select_expression_to_column_infos(combined_select_expression_for_ast)
            output_header = select_output_header(input_header, join_header, column_infos)
        query_context.select_expression = select_expression
        query_context.writer.set_header(output_header)

        if query_context.top_count is not None:
            query_context.writer = TopWriter(query_context.writer, query_context.top_count)
        if 'distinct_count' in rb_actions[SELECT]:
            query_context.writer = UniqCountWriter(query_context.writer)
        elif 'distinct' in rb_actions[SELECT]:
            query_context.writer = UniqWriter(query_context.writer)

    if ORDER_BY in rb_actions:
        query_context.sort_key_expression = '({})'.format(combine_string_literals(rb_actions[ORDER_BY]['text'], string_literals))
        query_context.writer = SortedWriter(query_context.writer, reverse_sort=rb_actions[ORDER_BY]['reverse'])


def make_inconsistent_num_fields_warning(table_name, inconsistent_records_info):
    assert len(inconsistent_records_info) > 1
    inconsistent_records_info = inconsistent_records_info.items()
    inconsistent_records_info = sorted(inconsistent_records_info, key=lambda v: v[1])
    num_fields_1, record_num_1 = inconsistent_records_info[0]
    num_fields_2, record_num_2 = inconsistent_records_info[1]
    warn_msg = 'Number of fields in "{}" table is not consistent: '.format(table_name)
    warn_msg += 'e.g. record {} -> {} fields, record {} -> {} fields'.format(record_num_1, num_fields_1, record_num_2, num_fields_2)
    return warn_msg


def query(query_text, input_iterator, output_writer, output_warnings, join_tables_registry=None, user_init_code='', user_namespace=None):
    query_context = RBQLContext(input_iterator, output_writer, user_init_code)
    shallow_parse_input_query(query_text, input_iterator, join_tables_registry, query_context)
    compile_and_run(query_context, user_namespace)
    query_context.writer.finish()
    output_warnings.extend(query_context.input_iterator.get_warnings())
    if query_context.join_map_impl is not None:
        output_warnings.extend(query_context.join_map_impl.get_warnings())
    output_warnings.extend(output_writer.get_warnings())


class RBQLInputIterator:
    def get_variables_map(self, query_text):
        raise NotImplementedError('Unable to call the interface method')

    def get_record(self):
        raise NotImplementedError('Unable to call the interface method')

    def handle_query_modifier(self, modifier_name):
        # Reimplement if you need to handle a boolean query modifier that can be used like this: `SELECT * WITH (modifiername)`
        pass

    def get_warnings(self):
        return [] # Reimplement if your class can produce warnings

    def get_header(self):
        return None # Reimplement if your class can provide input header


class RBQLOutputWriter:
    def write(self, fields):
        raise NotImplementedError('Unable to call the interface method')

    def finish(self):
        pass # Reimplement if your class needs to do something on finish e.g. cleanup

    def get_warnings(self):
        return [] # Reimplement if your class can produce warnings

    def set_header(self, header):
        pass # Reimplement if your class can handle output headers in a meaningful way


class RBQLTableRegistry:
    # table_id - external table identifier like filename for csv files or variable name for pandas dataframes.
    # single_char_alias - either `a` (for input table) or `b` (for join table)
    def get_iterator_by_table_id(self, table_id, single_char_alias):
        raise NotImplementedError('Unable to call the interface method')

    def finish(self):
        pass # Reimplement if your class needs to do something on finish e.g. cleanup

    def get_warnings(self):
        return [] # Reimplement if your class can produce warnings


class TableIterator(RBQLInputIterator):
    def __init__(self, table, column_names=None, normalize_column_names=True, variable_prefix='a'):
        self.table = table
        self.column_names = column_names
        self.normalize_column_names = normalize_column_names
        self.variable_prefix = variable_prefix
        self.NR = 0
        self.fields_info = dict()

    def get_variables_map(self, query_text):
        variable_map = dict()
        parse_basic_variables(query_text, self.variable_prefix, variable_map)
        parse_array_variables(query_text, self.variable_prefix, variable_map)
        if self.column_names is not None:
            if len(self.table) and len(self.column_names) != len(self.table[0]):
                raise RbqlIOHandlingError('List of column names and table records have different lengths')
            if self.normalize_column_names:
                parse_dictionary_variables(query_text, self.variable_prefix, self.column_names, variable_map)
                parse_attribute_variables(query_text, self.variable_prefix, self.column_names, 'column names list', variable_map)
            else:
                map_variables_directly(query_text, self.column_names, variable_map)
        return variable_map

    def get_record(self):
        if self.NR >= len(self.table):
            return None
        record = self.table[self.NR]
        self.NR += 1
        num_fields = len(record)
        if num_fields not in self.fields_info:
            self.fields_info[num_fields] = self.NR
        return record

    def get_warnings(self):
        if len(self.fields_info) > 1:
            return [make_inconsistent_num_fields_warning('input', self.fields_info)]
        return []

    def get_header(self):
        return self.column_names


class TableWriter(RBQLOutputWriter):
    def __init__(self, external_table):
        self.table = external_table
        self.header = None

    def write(self, fields):
        self.table.append(fields)
        return True

    def set_header(self, header):
        self.header = header


ListTableInfo = namedtuple('ListTableInfo', ['table_id', 'table', 'column_names'])


class ListTableRegistry(RBQLTableRegistry):
    # Here table_infos is a list of ListTableInfo
    def __init__(self, table_infos, normalize_column_names=True):
        self.table_infos = table_infos
        self.normalize_column_names = normalize_column_names

    def get_iterator_by_table_id(self, table_id, single_char_alias):
        for table_info in self.table_infos: 
            if table_info.table_id == table_id:
                return TableIterator(table_info.table, table_info.column_names, self.normalize_column_names, single_char_alias)
        return None


def query_table(query_text, input_table, output_table, output_warnings, join_table=None, input_column_names=None, join_column_names=None, output_column_names=None, normalize_column_names=True, user_init_code=''):
    if not normalize_column_names and input_column_names is not None and join_column_names is not None:
        ensure_no_ambiguous_variables(query_text, input_column_names, join_column_names)
    input_iterator = TableIterator(input_table, input_column_names, normalize_column_names)
    output_writer = TableWriter(output_table)
    join_tables_registry = None if join_table is None else ListTableRegistry([ListTableInfo('b', join_table, join_column_names), ListTableInfo('B', join_table, join_column_names)], normalize_column_names)
    query(query_text, input_iterator, output_writer, output_warnings, join_tables_registry, user_init_code=user_init_code)
    if output_column_names is not None:
        assert len(output_column_names) == 0, '`output_column_names` param must be an empty list or None'
        if output_writer.header is not None:
            for column_name in output_writer.header:
                output_column_names.append(column_name)


def set_debug_mode(new_value=True):
    global debug_mode
    debug_mode = new_value

