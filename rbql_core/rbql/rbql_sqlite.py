# This module allows to query sqlite databases using RBQL


# TODO consider to support table names in "FROM" section of the query, making table_name param of SqliteRecordIterator optional
# TODO consider adding support for multiple variable_prefixes i.e. "a" and <table_name> or "b" and <join_table_name> to alias input and join tables


import re
import os
import sys

from . import rbql_engine
from . import rbql_csv


class SqliteRecordIterator(rbql_engine.RBQLInputIterator):
    def __init__(self, db_connection, table_name, variable_prefix='a'):
        self.db_connection = db_connection
        self.table_name = table_name
        self.variable_prefix = variable_prefix
        self.cursor = self.db_connection.cursor()
        import sqlite3
        if re.match('^[a-zA-Z0-9_]*$', table_name) is None:
            raise rbql_engine.RbqlIOHandlingError('Unable to use "{}": input table name can contain only alphanumeric characters and underscore'.format(table_name))
        try:
            self.cursor.execute('SELECT * FROM {};'.format(table_name))
        except sqlite3.OperationalError as e:
            if str(e).find('no such table') != -1:
                raise rbql_engine.RbqlIOHandlingError('no such table "{}"'.format(table_name))
            raise

    def get_header(self):
        column_names = [description[0] for description in self.cursor.description]
        return column_names

    def get_variables_map(self, query_text):
        variable_map = dict()
        rbql_engine.parse_basic_variables(query_text, self.variable_prefix, variable_map)
        rbql_engine.parse_array_variables(query_text, self.variable_prefix, variable_map)
        rbql_engine.parse_dictionary_variables(query_text, self.variable_prefix, self.get_header(), variable_map)
        rbql_engine.parse_attribute_variables(query_text, self.variable_prefix, self.get_header(), 'table column names', variable_map)
        return variable_map

    def get_record(self):
        record_tuple = self.cursor.fetchone()
        if record_tuple is None:
            return None
        # We need to convert tuple to list here because otherwise we won't be able to concatinate lists in expressions with star `*` operator
        return list(record_tuple)

    def get_all_records(self, num_rows=None):
        # TODO consider to use TOP in the sqlite query when num_rows is not None
        if num_rows is None:
            return self.cursor.fetchall()
        result = []
        for i in range(num_rows):
            row = self.cursor.fetchone()
            if row is None:
                break
            result.append(row)
        return result

    def get_warnings(self):
        return []


class SqliteDbRegistry(rbql_engine.RBQLTableRegistry):
    def __init__(self, db_connection):
        self.db_connection = db_connection

    def get_iterator_by_table_id(self, table_id, single_char_alias):
        self.record_iterator = SqliteRecordIterator(self.db_connection, table_id, single_char_alias)
        return self.record_iterator


def query_sqlite_to_csv(query_text, db_connection, input_table_name, output_path, output_delim, output_policy, output_csv_encoding, output_warnings, user_init_code='', colorize_output=False):
    output_stream, close_output_on_finish = (None, False)
    join_tables_registry = None
    try:
        output_stream, close_output_on_finish = (sys.stdout, False) if output_path is None else (open(output_path, 'wb'), True)

        if not rbql_csv.is_ascii(query_text) and output_csv_encoding == 'latin-1':
            raise rbql_engine.RbqlIOHandlingError('To use non-ascii characters in query enable UTF-8 encoding instead of latin-1/binary')

        if not rbql_csv.is_ascii(output_delim) and output_csv_encoding == 'latin-1':
            raise rbql_engine.RbqlIOHandlingError('To use non-ascii separators enable UTF-8 encoding instead of latin-1/binary')

        default_init_source_path = os.path.join(os.path.expanduser('~'), '.rbql_init_source.py')
        if user_init_code == '' and os.path.exists(default_init_source_path):
            user_init_code = rbql_csv.read_user_init_code(default_init_source_path)

        join_tables_registry = SqliteDbRegistry(db_connection)
        input_iterator = SqliteRecordIterator(db_connection, input_table_name)
        output_writer = rbql_csv.CSVWriter(output_stream, close_output_on_finish, output_csv_encoding, output_delim, output_policy, colorize_output=colorize_output)
        rbql_engine.query(query_text, input_iterator, output_writer, output_warnings, join_tables_registry, user_init_code)
    finally:
        if close_output_on_finish:
            output_stream.close()


