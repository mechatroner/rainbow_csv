import os
import sys
import codecs
import traceback
import subprocess
import tempfile
import time

import rbql
from rbql import rbql_csv

vim_interface = None


class VimInterface:
    def __init__(self):
        import vim
        self.vim = vim

    def set_vim_variable(self, var_name, value):
        escaped_value = value.replace("'", "''")
        self.vim.command("let {} = '{}'".format(var_name, escaped_value))

    def report_error_to_vim(self, query_status, details):
        self.set_vim_variable('psv_query_status', query_status)
        self.set_vim_variable('psv_error_report', details)


class CLIVimMediator:
    def __init__(self):
        self.psv_variables = dict()

    def set_vim_variable(self, var_name, value):
        self.psv_variables[var_name] = value

    def report_error_to_vim(self, query_status, details):
        self.set_vim_variable('psv_query_status', query_status)
        self.set_vim_variable('psv_error_report', details)

    def save_report(self, dst):
        query_status = self.psv_variables.get('psv_query_status', 'Unknown Error')
        dst_table_path = self.psv_variables.get('psv_dst_table_path', '')
        report = self.psv_variables.get('psv_error_report', '')
        if not len(report):
            report = self.psv_variables.get('psv_warning_report', '')
        dst.write(query_status + '\n')
        dst.write(dst_table_path + '\n')
        if len(report):
            dst.write(report + '\n')


def get_random_suffix():
    return str(time.time()).split('.')[0]


def execute_python(src_table_path, rb_script_path, encoding, input_delim, input_policy, input_comment_prefix, out_delim, out_policy, dst_table_path, with_headers, strip_spaces):
    query = codecs.open(rb_script_path, encoding=encoding).read()
    warnings = []
    try:
        rbql.query_csv(query, src_table_path, input_delim, input_policy, dst_table_path, out_delim, out_policy, encoding, warnings, with_headers, comment_prefix=input_comment_prefix, strip_whitespaces=strip_spaces)
        warning_report = '\n'.join(warnings)
        vim_interface.set_vim_variable('psv_warning_report', warning_report)
        vim_interface.set_vim_variable('psv_query_status', 'OK')
    except Exception as e:
        error_type, error_msg = rbql.exception_to_error_info(e)
        vim_interface.report_error_to_vim(error_type, error_msg)


def converged_execute(src_table_path, rb_script_path, encoding, input_delim, input_policy, input_comment_prefix, out_delim, out_policy, with_headers, strip_spaces):
    try:
        input_delim = rbql_csv.normalize_delim(input_delim)
        out_delim = rbql_csv.normalize_delim(out_delim)
        tmp_dir = tempfile.gettempdir()
        table_name = os.path.basename(src_table_path)
        dst_table_name = '{}.txt'.format(table_name)
        dst_table_path = os.path.join(tmp_dir, dst_table_name)
        vim_interface.set_vim_variable('psv_dst_table_path', dst_table_path)
        execute_python(src_table_path, rb_script_path, encoding, input_delim, input_policy, input_comment_prefix, out_delim, out_policy, dst_table_path, with_headers, strip_spaces)
    except Exception as e:
        vim_interface.report_error_to_vim('Execution Error', str(e))


def run_execute(src_table_path, rb_script_path, encoding, input_delim, input_policy, input_comment_prefix, out_delim, out_policy, with_headers, strip_spaces):
    global vim_interface
    vim_interface = VimInterface()
    converged_execute(src_table_path, rb_script_path, encoding, input_delim, input_policy, input_comment_prefix, out_delim, out_policy, with_headers, strip_spaces)


def run_execute_cli(src_table_path, rb_script_path, encoding, input_delim, input_policy, input_comment_prefix, out_delim, out_policy, with_headers, strip_spaces):
    global vim_interface
    vim_interface = CLIVimMediator()
    converged_execute(src_table_path, rb_script_path, encoding, input_delim, input_policy, input_comment_prefix, out_delim, out_policy, with_headers, strip_spaces)
    vim_interface.save_report(sys.stdout)


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('input_table_path', metavar='FILE', help='Read csv table from FILE')
    parser.add_argument('query_file', metavar='FILE', help='Read rbql query from FILE')
    parser.add_argument('encoding', metavar='ENCODING', help='rbql encoding')
    parser.add_argument('input_delim', metavar='DELIM', help='Input delimiter')
    parser.add_argument('input_policy', metavar='POLICY', help='Input policy')
    parser.add_argument('input_comment_prefix', metavar='PREFIX', help='Input comment prefix')
    parser.add_argument('out_delim', metavar='DELIM', help='Output delimiter')
    parser.add_argument('out_policy', metavar='POLICY', help='Output policy')
    parser.add_argument('with_headers', metavar='WITH_HEADERS', help='With headers')
    parser.add_argument('strip_spaces', metavar='STRIP_SPACES', help='Strip Spaces')
    args = parser.parse_args()

    with_headers = {'True': True, 'False': False}[args.with_headers]
    strip_spaces = {'True': True, 'False': False}[args.strip_spaces]

    run_execute_cli(args.input_table_path, args.query_file, args.encoding, args.input_delim, args.input_policy, args.input_comment_prefix, args.out_delim, args.out_policy, with_headers, strip_spaces)


if __name__ == '__main__':
    main()
