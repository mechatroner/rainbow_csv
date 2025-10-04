from . import rbql_engine
from . import rbql_pandas

# TODO figure out how to implement at least basic autocomplete for the magic command.

import re
from_autocomplete_matcher = re.compile(r'(?:^| )from +([_a-zA-Z0-9]+)(?:$| )', flags=re.IGNORECASE)
join_autocomplete_matcher = re.compile(r'(?:^| )join +([_a-zA-Z0-9]+)(?:$| )', flags=re.IGNORECASE)


class IPythonDataframeRegistry(rbql_engine.RBQLTableRegistry):
    # TODO consider making this class nested under load_ipython_extension to avoid redundant `import pandas`.
    def __init__(self, all_ns_refs):
        self.all_ns_refs = all_ns_refs

    def get_iterator_by_table_id(self, table_id, single_char_alias):
        import pandas
        # It seems to be the first namespace is "user" namespace, at least according to this code: 
        # https://github.com/google/picatrix/blob/a2f39766ad4b007b125dc8f84916e18fb3dc5478/picatrix/lib/utils.py
        for ns in self.all_ns_refs:
            if table_id in ns and isinstance(ns[table_id], pandas.DataFrame):
                return rbql_pandas.DataframeIterator(ns[table_id], normalize_column_names=True, variable_prefix=single_char_alias)
        return None


def eprint(*args, **kwargs):
    import sys
    print(*args, file=sys.stderr, **kwargs)


class AttrDict(dict):
    # Helper class to convert dict keys to attributes. See explanation here: https://stackoverflow.com/a/14620633/2898283
    def __init__(self, *args, **kwargs):
        super(AttrDict, self).__init__(*args, **kwargs)
        self.__dict__ = self


def load_ipython_extension(ipython):
    from IPython.core.magic import register_line_magic
    from IPython.core.getipython import get_ipython
    import pandas

    ipython = ipython or get_ipython() # The pattern taken from here: https://github.com/pydoit/doit/blob/9efe141a5dc96d4912143561695af7fc4a076490/doit/tools.py
    # ipython is interactiveshell. Docs: https://ipython.readthedocs.io/en/stable/api/generated/IPython.core.interactiveshell.html


    def get_table_column_names(table_id):
        user_namespace = ipython.all_ns_refs[0] if len(ipython.all_ns_refs) else dict()
        if table_id not in user_namespace or not isinstance(user_namespace[table_id], pandas.DataFrame):
            return []
        input_df = user_namespace[table_id]
        if isinstance(input_df.columns, pandas.RangeIndex) or not len(input_df.columns):
            return []
        return [str(v) for v in list(input_df.columns)]


    def rbql_completers(self, event):
        # This should return a list of strings with possible completions.
        # Note that all the included strings that don't start with event.symbol
        # are removed, in order to not confuse readline.

        # eg Typing %%rbql foo then hitting tab would yield an event like so: namespace(command='%%rbql', line='%%rbql foo', symbol='foo', text_until_cursor='%%rbql foo')
        # https://stackoverflow.com/questions/36479197/ipython-custom-tab-completion-for-user-magic-function
        # https://github.com/ipython/ipython/issues/11878

        simple_sql_keys_lower_case = ['update', 'select', 'where', 'limit', 'from', 'group by', 'order by']
        simple_sql_keys_upper_case = [sk.upper() for sk in simple_sql_keys_lower_case]
        autocomplete_suggestions = simple_sql_keys_lower_case + simple_sql_keys_upper_case

        if event.symbol and event.symbol.startswith('a.'):
            from_match = from_autocomplete_matcher.search(event.line)
            if from_match is not None:
                table_id = from_match.group(1)
                table_column_names = get_table_column_names(table_id)
                autocomplete_suggestions += ['a.' + cn for cn in table_column_names]

        if event.symbol and event.symbol.startswith('b.'):
            from_match = join_autocomplete_matcher.search(event.line)
            if from_match is not None:
                table_id = from_match.group(1)
                table_column_names = get_table_column_names(table_id)
                autocomplete_suggestions += ['b.' + cn for cn in table_column_names]
        
        return autocomplete_suggestions

    ipython.set_hook('complete_command', rbql_completers, str_key='%rbql')


    # The difference between line and cell magic is described here: https://jakevdp.github.io/PythonDataScienceHandbook/01.03-magic-commands.html.
    # In short: line magic only accepts one line of input whereas cell magic supports multiline input as magic command argument.
    # Both line and cell magic would make sense for RBQL queries but for MVP it should be enough to implement just the cell magic.
    @register_line_magic("rbql")
    def run_rbql_query(query_text):
        # Unfortunately globals() and locals() called from here won't contain user variables defined in the notebook.

        tables_registry = IPythonDataframeRegistry(ipython.all_ns_refs)
        output_writer = rbql_pandas.DataframeWriter()
        # Ignore warnings because pandas dataframes can't cause them.
        output_warnings = []
        # TODO make it possible to specify user_init_code in code cells.
        error_type, error_msg = None, None
        user_namespace = None
        if len(ipython.all_ns_refs) > 0:
            user_namespace = AttrDict(ipython.all_ns_refs[0])
        try:
            rbql_engine.query(query_text, input_iterator=None, output_writer=output_writer, output_warnings=output_warnings, join_tables_registry=tables_registry, user_init_code='', user_namespace=user_namespace)
        except Exception as e:
            error_type, error_msg = rbql_engine.exception_to_error_info(e)
        if error_type is None:
            return output_writer.result
        else:
            # TODO use IPython.display to print error in red color, see https://stackoverflow.com/questions/16816013/is-it-possible-to-print-using-different-colors-in-ipythons-notebook
            eprint('Error [{}]: {}'.format(error_type, error_msg))
