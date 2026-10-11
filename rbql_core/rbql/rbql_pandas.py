from . import rbql_engine


def get_dataframe_column_names_for_rbql(dataframe):
    import pandas
    if isinstance(dataframe.columns, pandas.RangeIndex) or not len(dataframe.columns):
        return None
    return [str(v) for v in list(dataframe.columns)]


class DataframeIterator(rbql_engine.RBQLInputIterator):
    def __init__(self, table, variable_prefix='a'):
        self.table = table
        self.variable_prefix = variable_prefix
        self.record_number = 0
        # TODO include `Index` into the list of addressable variable names.
        self.column_names = get_dataframe_column_names_for_rbql(table)
        self.table_itertuples = self.table.itertuples(index=False)

    def get_record(self):
        try:
            record = next(self.table_itertuples)
        except StopIteration:
            return None
        self.record_number += 1
        # Convert to list because `record` has `Pandas` type.
        return list(record)

    def get_warnings(self):
        return []

    def get_header(self):
        return self.column_names


class DataframeWriter(rbql_engine.RBQLOutputWriter):
    def __init__(self):
        self.header = None
        self.output_rows = []
        self.result = None

    def write(self, fields):
        self.output_rows.append(fields)
        return True

    def set_header(self, header):
        self.header = header

    def finish(self):
        import pandas as pd
        self.result = pd.DataFrame(self.output_rows, columns=self.header)


class SingleDataframeRegistry(rbql_engine.RBQLTableRegistry):
    def __init__(self, table, table_name):
        self.table = table
        self.table_name = table_name

    def get_iterator_by_table_id(self, table_id, single_char_alias):
        if table_id.lower() != self.table_name:
            raise rbql_engine.RbqlParsingError('Unable to find join table: "{}"'.format(table_id))
        return DataframeIterator(self.table, single_char_alias)


def query_dataframe(query_text, input_dataframe, output_warnings=None, join_dataframe=None, user_init_code=''):
    if output_warnings is None:
        # Ignore output warnings if the output_warnings container hasn't been provided.
        output_warnings = []
    input_iterator = DataframeIterator(input_dataframe)
    output_writer = DataframeWriter()
    join_tables_registry = None if join_dataframe is None else SingleDataframeRegistry(join_dataframe, 'b')
    rbql_engine.query(query_text, input_iterator, output_writer, output_warnings, join_tables_registry, user_init_code=user_init_code)
    return output_writer.result
