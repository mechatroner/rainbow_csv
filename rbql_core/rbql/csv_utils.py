import re


newline_rgx = re.compile('(?:\r\n)|\r|\n')

field_regular_expression = '"((?:[^"]*"")*[^"]*)"'
field_rgx = re.compile(field_regular_expression)
field_rgx_external_whitespaces = re.compile(' *' + field_regular_expression + ' *')


def extract_next_field(src, dlm, preserve_quotes_and_whitespaces, allow_external_whitespaces, cidx, result):
    warning = False
    rgx = field_rgx_external_whitespaces if allow_external_whitespaces else field_rgx
    match_obj = rgx.match(src, cidx)
    if match_obj is not None:
        match_end = match_obj.span()[1]
        if match_end == len(src) or src[match_end] == dlm:
            if preserve_quotes_and_whitespaces:
                result.append(match_obj.group(0))
            else:
                result.append(match_obj.group(1).replace('""', '"'))
            return (match_end + 1, False)
        warning = True
    uidx = src.find(dlm, cidx)
    if uidx == -1:
        uidx = len(src)
    field = src[cidx:uidx]
    warning = warning or field.find('"') != -1
    result.append(field)
    return (uidx + 1, warning)



def split_quoted_str(src, dlm, preserve_quotes_and_whitespaces=False):
    # This function is newline-agnostic i.e. it can also split records with multiline fields.
    assert dlm != '"'
    if src.find('"') == -1: # Optimization for most common case
        return (src.split(dlm), False)
    result = list()
    cidx = 0
    warning = False
    allow_external_whitespaces = dlm != ' '
    while cidx < len(src):
        extraction_report = extract_next_field(src, dlm, preserve_quotes_and_whitespaces, allow_external_whitespaces, cidx, result)
        cidx = extraction_report[0]
        warning = warning or extraction_report[1]

    if src[-1] == dlm:
        result.append('')
    return (result, warning)


def split_whitespace_separated_str(src, preserve_whitespaces=False):
    rgxp = re.compile(" *[^ ]+ *") if preserve_whitespaces else re.compile("[^ ]+")
    result = []
    for m in rgxp.finditer(src):
        result.append(m.group())
    if preserve_whitespaces and len(result) > 1:
        for i in range(len(result) - 1):
            result[i] = result[i][:-1]
    return result


def smart_split(src, dlm, policy, preserve_quotes_and_whitespaces):
    if policy == 'simple':
        return (src.split(dlm), False)
    if policy == 'whitespace':
        return (split_whitespace_separated_str(src, preserve_quotes_and_whitespaces), False)
    if policy == 'monocolumn':
        return ([src], False)
    return split_quoted_str(src, dlm, preserve_quotes_and_whitespaces)


def extract_line_from_data(data):
    mobj = newline_rgx.search(data)
    if mobj is None:
        return (None, None, data)
    pos_start, pos_end = mobj.span()
    str_before = data[:pos_start]
    str_after = data[pos_end:]
    return (str_before, mobj.group(0), str_after)


def quote_field(src, delim):
    if src.find('"') != -1:
        return '"{}"'.format(src.replace('"', '""'))
    if src.find(delim) != -1:
        return '"{}"'.format(src)
    return src


def rfc_quote_field(src, delim):
    # A single regexp can be used to find all 4 characters simultaneously, but this approach doesn't significantly improve performance according to my tests.
    if src.find('"') != -1:
        return '"{}"'.format(src.replace('"', '""'))
    if src.find(delim) != -1 or src.find('\n') != -1 or src.find('\r') != -1:
        return '"{}"'.format(src)
    return src


def unquote_field(field):
    field_rgx_external_whitespaces_full = re.compile('^ *'+ field_regular_expression + ' *$')
    match_obj = field_rgx_external_whitespaces_full.match(field)
    if match_obj is not None:
        return match_obj.group(1).replace('""', '"')
    return field


def unquote_fields(fields):
    return [unquote_field(f) for f in fields]


