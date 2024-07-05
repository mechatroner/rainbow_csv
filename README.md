# Rainbow CSV

![rainbow_csv](https://i.imgur.com/EhV2niB.png)

## Installation
Use your favorite package manager.  

Vundle: `Plugin 'mechatroner/rainbow_csv'`  
VimPlug: `Plug 'mechatroner/rainbow_csv'`  
dein: `call dein#add('mechatroner/rainbow_csv')`  

No additional steps required - Rainbow CSV will work out of the box.  

## Overview
Main features:  
* Highlight CSV columns in different rainbow colors. 
* Provide info about column under the cursor
* Provide `SELECT` and `UPDATE` queries in RBQL: SQL-like transprogramming query language.
* Consistency check for csv files (CSVLint)
* Align and Shrink CSV fields (add/remove trailing spaces in fields)
* Cell-level cursor navigation

There are 4 ways to enable csv columns highlighting:
1. CSV autodetection based on file content and/or extension  
2. Manual CSV delimiter selection with `:RainbowDelim` command with cursor over the delimiter  
3. Manual CSV delimiter selection with `:RainbowMultiDelim` for multi-character delimiters selecting them in "VISUAL" mode  
4. Explicitly activate one of the built-in filetypes, e.g. `:set ft=csv`  

The core functionality of the plugin is written in pure vimscript, no additional libraries required.  

![Rainbow CSV Screenshot](https://user-images.githubusercontent.com/5349737/190057249-8ec401f6-b76d-4420-a6af-053dd502f8a9.png)

# Plugin description

### Built-in and autogenerated filetypes
Rainbow CSV has 7 built-in CSV filetypes and infinite number of autogenerated filetypes.  
Each Rainbow CSV filetype is mapped to a separator and "policy" which describes additional properties e.g. if separator can be escaped inside double quoted field.  
If you run `:RainbowDelim` or `:RainbowMultiDelim` to select a separator that doesn't map to one of the built-in filetypes, Rainbow CSV will dynamically generate the filetype syntax file and put it into the "syntax" folder.  
List of built-in filetypes:  

|Filetype       | Separator     | Extension | Properties                                          |
|---------------|---------------|-----------|-----------------------------------------------------|
|csv            | , (comma)     | .csv      | Ignored inside double-quoted fields                 |
|tsv            | \t (TAB)      | .tsv .tab |                                                     |
|csv_semicolon  | ; (semicolon) |           | Ignored inside double-quoted fields                 |
|csv_whitespace | whitespace    |           | Consecutive whitespaces are merged                  |
|csv_pipe       | &#124; (pipe) |           |                                                     |
|rfc_csv        | , (comma)     |           | Same as "csv" but allows multiline fields           |
|rfc_semicolon  | ; (semicolon) |           | Same as "csv_semicolon" but allows multiline fields |


### Associating file extensions with CSV dialects
In most cases the built-in autodetection algorithm should correctly detect correct CSV dialect for all CSV tables that you open in Vim, but if you have disabled the autodetection algorithm or don't want to rely on it for some reason, you can manually associate file extensions with available csv dialects.  
Example: to associate ".dat" extension with "csv_pipe" dialect and ".csv" extension with "csv_semicolon" add the folowing lines to your .vimrc:  
```
autocmd BufNewFile,BufRead *.csv   set filetype=csv_semicolon
autocmd BufNewFile,BufRead *.dat   set filetype=csv_pipe
```

### Working with multiline CSV fields
In rare cases some CSV files can contain double-quoted fields spanning multiple lines.  
To work with such files you can set filetype to either "rfc_csv" or "rfc_semicolon" e.g. `:set ft=rfc_csv`.  
Syntax highlighting for rfc_csv and rfc_semicolon dialects can sometimes go out of sync with the file content, use `:syntax sync fromstart` command in that case.  
rfc_csv and rfc_semicolon are fully supported by RBQL which among other things allows you to easily convert them to line-by-line CSV by replacing newlines in fields with sequences of 4 spaces or something like that.  
rfc_csv and rfc_semicolon take their name from [RFC 4180](https://tools.ietf.org/html/rfc4180) memo with which they are fully compatible.  


### Built-in RBQL query language
Rainbow CSV comes with built-in lightweight RBQL SQL-like query engine.  
To run an RBQL query either use `:Select` command  e.g. `:Select a1, a2` or run `:RainbowQuery` command to enter query editing mode.  

Demonstration of rainbow_csv highlighting and RBQL queries 


![demo_screencast](https://i.imgur.com/4PIVvjc.gif)


In this demo python expressions were used, but JavaScript is also available.


### Rainbow highlighting for non-table files
You can use rainbow highlighting and RBQL even for non-csv/tsv files.  
E.g. you can highlight records in log files, one-line xmls and other delimited records.  
You can even highlight function arguments in your programming language using comma or comma+whitespaces as a delimiter for `:RainbowDelim` or `:RainbowMultiDelim` commands.  
And you can always turn off the rainbow highlighting using `:NoRainbowDelim` command.  


### Commands

#### :RainbowDelim

Mark current file as a table and highlight it's columns in rainbow colors. Character under the cursor will be used as a delimiter. The delimiter will be saved in a config file for future vim sessions.

You can also use this command for non-csv files, e.g. to highlight function arguments  
in source code in different colors. To return back to original syntax highlighting run `:NoRainbowDelim`

#### :RainbowMultiDelim

Same as `:RainbowDelim`, but works with multicharacter separators.  
Visually select the multicharacter separator (e.g. `~#~`) and run `:RainbowMultiDelim` command.

#### :NoRainbowDelim

Disable rainbow columns highlighting for the current file.

#### :RainbowCellGoUp

Move cursor one cell up.  
Consider mapping this to Ctrl+[Up Arrow], see the "Key Mappings" section.

#### :RainbowCellGoDown

Move cursor one cell down.  
Consider mapping this to Ctrl+[Down Arrow], see the "Key Mappings" section.

#### :RainbowCellGoLeft

Move cursor one cell left.  
Consider mapping this to Ctrl+[Left Arrow], see the "Key Mappings" section.

#### :RainbowCellGoRight

Move cursor one cell right.  
Consider mapping this to Ctrl+[Right Arrow], see the "Key Mappings" section.


#### :RainbowComment
Mark the character under the cursor as the comment prefix, e.g. `#`. By default Rainbow CSV doesn't highlight comments in CSV files.  
You can also use `:RainbowCommentMulti` to mark a visual selection as a multicharacter comment prefix  


#### :NoRainbowComment
Disable all comments for the current CSV file.  
This command is especially useful when you have set `g:rainbow_comment_prefix` variable and want to exclude just one particular file.  


#### :CSVLint

The linter checks the following:  
* consistency of double quotes usage in CSV rows  
* consistency of number of fields per CSV row  

#### :RainbowAlign

Align CSV columns with whitespaces.  
Don't run this command if you treat leading and trailing whitespaces in fields as part of the data.  
You can edit aligned CSV file in Vim column-edit mode (Ctrl+v).  

#### :RainbowShrink

Remove leading and trailing whitespaces from all fields. Opposite to RainbowAlign

#### :Select ...

Allows to enter RBQL select query as vim command.  
E.g. `:Select a1, a2 order by a1`

#### :Update ...

Allows to enter RBQL update query as vim command.  
E.g. `:Update a1 = a1 + " " + a2`

#### :RainbowQuery

Enter RBQL Query editing mode.  
When in the query editing mode, execute `:RainbowQuery` again to run the query.  
Consider mapping `:RainbowQuery` to `<F5>` key i.e. `nnoremap <F5> :RainbowQuery<CR>`


#### :RainbowName \<name\>

Assign any name to the current table. You can use this name in join operation instead of the table path. E.g.
```
JOIN customers ON a1 == b1
``` 
intead of:
```
JOIN /path/to/my/customers/table ON a1 == b1
```

#### :RainbowCopyBack

This command only applicable for RBQL output files.  
Replace the content of the original file that was used to run the RBQL query with the query result set data.


### Key Mappings
Plugin does not create any new key mappings, but you can define your own in your .vimrc file.  
All highlighted files have a special buffer variable `b:rbcsv` set to 1, so you can use this to define conditional csv-only key mappings.  
For example, to conditionally map Ctrl+Arrow keys to cell navigation commands you can use this snippet:

```
nnoremap <expr> <C-Left> get(b:, 'rbcsv', 0) == 1 ? ':RainbowCellGoLeft<CR>' : '<C-Left>'
nnoremap <expr> <C-Right> get(b:, 'rbcsv', 0) == 1 ? ':RainbowCellGoRight<CR>' : '<C-Right>'
nnoremap <expr> <C-Up> get(b:, 'rbcsv', 0) == 1 ? ':RainbowCellGoUp<CR>' : '<C-Up>'
nnoremap <expr> <C-Down> get(b:, 'rbcsv', 0) == 1 ? ':RainbowCellGoDown<CR>' : '<C-Down>'
```

You can also map arrow keys unconditionally, but this will have no effect outside highlighted CSV files, e.g.
```
nnoremap <C-Right> :RainbowCellGoRight<CR>
```

### Configuration

#### g:disable_rainbow_hover
Set to `1` to stop showing info about the column under the cursor in Vim command line  
Example:  
```
let g:disable_rainbow_hover = 1
```

#### g:rcsv_delimiters
Default: `["\t", ",", ";", "|"]`  
List of separators to try for content-based autodetection  
You can add or remove values from the list. Example:
```
let g:rcsv_delimiters = ["\t", ",", "^", "~#~"]
```

#### g:disable_rainbow_csv_autodetect
Set to `1` to disable CSV autodetection mechanism  
Example:  
```
let g:disable_rainbow_csv_autodetect = 1
```
Manual delimiter selection would still be possible. 
You can also manually associate specific file extensions with 'csv' or 'tsv' filetypes  

#### g:rainbow_comment_prefix
Default: `''`  
A string to use as a comment prefix for all CSV files you open in Vim.  
This setting is helpful if you are dealing with lots of CSV files which consistently use the same comment prefix e.g. `'#'` or `'>>'`  
If you want to enable comments on file-by-file basis, use the `:RainbowComment` or `:RainbowCommentMulti` commands instead.  
To cancel the effect of `g:rainbow_comment_prefix` just for the current file use `:NoRainbowComment` command.  


#### g:rcsv_max_columns
Default: `30`  
Autodetection will fail if buffer has more than _g:rcsv\_max\_columns_ columns.  
You can increase or decrease this limit.

#### g:rcsv_colorpairs
List of color name pairs to customize rainbow highlighting.  
Each entry in the list is a pair of two colors: the first color is for terminal mode, the second one is for GUI mode.  
Example:
```
let g:rcsv_colorpairs = [['red', 'red'], ['blue', 'blue'], ['green', 'green'], ['magenta', 'magenta'], ['NONE', 'NONE'], ['darkred', 'darkred'], ['darkblue', 'darkblue'], ['darkgreen', 'darkgreen'], ['darkmagenta', 'darkmagenta'], ['darkcyan', 'darkcyan']]
```

#### g:multiline_search_range
Default: `10`  
This settings is only relevant for rfc_csv and rfc_semicolon dialects.  
If some multiline records contain more lines that this value, hover info will not work correctly. It is not recommended to significantly increase this value because it will have negative impact on hover info performance 

#### g:rbql_backend_language
Default: `'python'`  
Supported values: `'python'`, `'js'`  

Scripting language to use in RBQL expressions.


#### g:rbql_encoding
Default: `utf-8`  
Supported values: `'utf-8'`, `'latin-1'`  

CSV files encoding for RBQL. 


#### g:rbql_output_format
Default: `'input'`  
Supported values: `'tsv'`, `'csv'`, `'input'`

Format of RBQL result set tables.

* input: same format as the input table
* tsv: doesn't allow quoted tabs inside fields. 
* csv: is Excel-compatible and allows quoted commas.

Essentially format is a pair: delimiter + quoting policy.  
This setting for example can be used to convert files between tsv and csv format:
* To convert _csv_ to _tsv_: **1.** open csv file. **2.** `:let g:rbql_output_format='tsv'` **3.** `:Select *`
* To convert _tsv_ to _csv_: **1.** open tsv file. **2.** `:let g:rbql_output_format='csv'` **3.** `:Select *`


#### g:rbql_use_system_python
Set to `1` to use system python interpreter for RBQL queries instead of the python interpreter built into your vim/neovim editor.


#### g:rbql_with_headers
If most of the CSV files that you work with have headers, you can set this value to 1. In this case RBQL will treat first records in files as headers by default.  
Example: `:let g:rbql_with_headers = 1`  
You can also adjust (or override) this setting by adding `WITH (header)` or `WITH (noheader)` to the end of your RBQL queries.

#### g:rbql_trim_spaces
Default: `1`  
Trim/Strip all trailing and leading spaces in all fields when running RBQL.  
Set to `0` to preserve leading and trailing spaces in output, this might also slightly improve performance.


# RBQL (Rainbow Query Language) Description

RBQL is an eval-based SQL-like query engine for (not only) CSV file processing. It provides SQL-like language that supports SELECT queries with Python or JavaScript expressions.  
RBQL is best suited for data transformation, data cleaning, and analytical queries.  
RBQL is distributed with CLI apps, text editor plugins, Python and JS libraries.  

[Official Site](https://rbql.org/)

### Main Features

* Use Python or JavaScript expressions inside `SELECT`, `UPDATE`, `WHERE` and `ORDER BY` statements
* Supports multiple input formats
* Result set of any query immediately becomes a first-class table on its own
* No need to provide FROM statement in the query when the input table is defined by the current context.
* Supports all main SQL keywords
* Supports aggregate functions and GROUP BY queries
* Supports user-defined functions (UDF)
* Provides some new useful query modes which traditional SQL engines do not have
* Lightweight, dependency-free, works out of the box

#### Limitations:

* RBQL doesn't support nested queries, but they can be emulated with consecutive queries
* Number of tables in all JOIN queries is always 2 (input table and join table), use consecutive queries to join 3 or more tables

### Supported SQL Keywords (Keywords are case insensitive)

* SELECT
* UPDATE
* WHERE
* ORDER BY ... [ DESC | ASC ]
* [ LEFT | INNER ] JOIN
* DISTINCT
* GROUP BY
* TOP _N_
* LIMIT _N_
* AS

All keywords have the same meaning as in SQL queries. You can check them [online](https://www.w3schools.com/sql/default.asp)  


### RBQL variables
RBQL for CSV files provides the following variables which you can use in your queries:

* _a1_, _a2_,..., _a{N}_  
   Variable type: **string**  
   Description: value of i-th field in the current record in input table  
* _b1_, _b2_,..., _b{N}_  
   Variable type: **string**  
   Description: value of i-th field in the current record in join table B  
* _NR_  
   Variable type: **integer**  
   Description: Record number (1-based)  
* _NF_  
   Variable type: **integer**  
   Description: Number of fields in the current record  
* _a.name_, _b.Person_age_, ... _a.{Good_alphanumeric_column_name}_  
   Variable type: **string**  
   Description: Value of the field referenced by it's "name". You can use this notation if the field in the header has a "good" alphanumeric name  
* _a["object id"]_, _a['9.12341234']_, _b["%$ !! 10 20"]_ ... _a["Arbitrary column name!"]_  
   Variable type: **string**  
   Description: Value of the field referenced by it's "name". You can use this notation to reference fields by arbitrary values in the header


### UPDATE statement

_UPDATE_ query produces a new table where original values are replaced according to the UPDATE expression, so it can also be considered a special type of SELECT query.

### Aggregate functions and queries

RBQL supports the following aggregate functions, which can also be used with _GROUP BY_ keyword:  
_COUNT_, _ARRAY_AGG_, _MIN_, _MAX_, _ANY_VALUE_, _SUM_, _AVG_, _VARIANCE_, _MEDIAN_  

Limitation: aggregate functions inside Python (or JS) expressions are not supported. Although you can use expressions inside aggregate functions.  
E.g. `MAX(float(a1) / 1000)` - valid; `MAX(a1) / 1000` - invalid.  
There is a workaround for the limitation above for _ARRAY_AGG_ function which supports an optional parameter - a callback function that can do something with the aggregated array. Example:  
`SELECT a2, ARRAY_AGG(a1, lambda v: sorted(v)[:5]) GROUP BY a2` - Python; `SELECT a2, ARRAY_AGG(a1, v => v.sort().slice(0, 5)) GROUP BY a2` - JS


### JOIN statements

Join table B can be referenced either by its file path or by its name - an arbitrary string which the user should provide before executing the JOIN query.  
RBQL supports _STRICT LEFT JOIN_ which is like _LEFT JOIN_, but generates an error if any key in the left table "A" doesn't have exactly one matching key in the right table "B".  
Table B path can be either relative to the working dir, relative to the main table or absolute.  
Limitation: _JOIN_ statements can't contain Python/JS expressions and must have the following form: _<JOIN\_KEYWORD> (/path/to/table.tsv | table_name ) ON a... == b... [AND a... == b... [AND ... ]]_

### SELECT EXCEPT statement

SELECT EXCEPT can be used to select everything except specific columns. E.g. to select everything but columns 2 and 4, run: `SELECT * EXCEPT a2, a4`  
Traditional SQL engines do not support this query mode.


### UNNEST() operator
UNNEST(list) takes a list/array as an argument and repeats the output record multiple times - one time for each value from the list argument.  
Example: `SELECT a1, UNNEST(a2.split(';'))`  


### LIKE() function
RBQL does not support LIKE operator, instead it provides "like()" function which can be used like this:
`SELECT * where like(a1, 'foo%bar')`


### WITH (header) and WITH (noheader) statements
You can set whether the input (and join) CSV file has a header or not using the environment configuration parameters which could be `--with_headers` CLI flag or GUI checkbox or something else.
But it is also possible to override this selection directly in the query by adding either `WITH (header)` or `WITH (noheader)` statement at the end of the query.
Example: `select top 5 NR, * with (header)`


### User Defined Functions (UDF)

RBQL supports User Defined Functions  
You can define custom functions and/or import libraries in two special files:  
* `~/.rbql_init_source.py` - for Python
* `~/.rbql_init_source.js` - for JavaScript


## Examples of RBQL queries

#### With Python expressions

* `SELECT TOP 100 a1, int(a2) * 10, len(a4) WHERE a1 == "Buy" ORDER BY int(a2) DESC`
* `SELECT a.id, a.weight / 1000 AS weight_kg`
* `SELECT * ORDER BY random.random()` - random sort
* `SELECT len(a.vehicle_price) / 10, a2 WHERE int(a.vehicle_price) < 500 and a['Vehicle type'] in ["car", "plane", "boat"] limit 20` - referencing columns by names from header and using Python's "in" to emulate SQL's "in"
* `UPDATE SET a3 = 'NPC' WHERE a3.find('Non-playable character') != -1`
* `SELECT NR, *` - enumerate records, NR is 1-based
* `SELECT * WHERE re.match(".*ab.*", a1) is not None` - select entries where first column has "ab" pattern
* `SELECT a1, b1, b2 INNER JOIN ./countries.txt ON a2 == b1 ORDER BY a1, a3` - example of join query
* `SELECT MAX(a1), MIN(a1) WHERE a.Name != 'John' GROUP BY a2, a3` - example of aggregate query
* `SELECT *a1.split(':')` - Using Python3 unpack operator to split one column into many. Do not try this with other SQL engines!

#### With JavaScript expressions

* `SELECT TOP 100 a1, a2 * 10, a4.length WHERE a1 == "Buy" ORDER BY parseInt(a2) DESC`
* `SELECT a.id, a.weight / 1000 AS weight_kg`
* `SELECT * ORDER BY Math.random()` - random sort
* `SELECT TOP 20 a.vehicle_price.length / 10, a2 WHERE parseInt(a.vehicle_price) < 500 && ["car", "plane", "boat"].indexOf(a['Vehicle type']) > -1 limit 20` - referencing columns by names from header
* `UPDATE SET a3 = 'NPC' WHERE a3.indexOf('Non-playable character') != -1`
* `SELECT NR, *` - enumerate records, NR is 1-based
* `SELECT a1, b1, b2 INNER JOIN ./countries.txt ON a2 == b1 ORDER BY a1, a3` - example of join query
* `SELECT MAX(a1), MIN(a1) WHERE a.Name != 'John' GROUP BY a2, a3` - example of aggregate query
* `SELECT ...a1.split(':')` - Using JS "destructuring assignment" syntax to split one column into many. Do not try this with other SQL engines!


# General info

### Comparison of Rainbow CSV technology with traditional graphical column alignment

#### Advantages

* WYSIWYG  
* Familiar editing environment of your favorite text editor  
* Zero-cost abstraction: Syntax highlighting is essentially free, while graphical column alignment can be computationally expensive  
* High information density: Rainbow CSV shows more data per screen because it doesn't insert column-aligning whitespaces.
* Works with non-table and semi-tabular files (text files that contain both table(s) and non-table data like text)
* Ability to visually associate two same-colored columns from two different windows. This is not possible with graphical column alignment  

#### Disadvantages

* Rainbow CSV technology may be less effective for CSV files with many (> 10) columns

### References


#### Rainbow CSV and similar plugins in other editors:

* Rainbow CSV for [Neovim](https://github.com/cameron-wags/rainbow_csv.nvim) - fork of Vim plugin, has some improvements and optimizations.
* Rainbow CSV extension in [Visual Studio Code](https://marketplace.visualstudio.com/items?itemName=mechatroner.rainbow-csv)
* rainbow_csv plugin in [Sublime Text](https://packagecontrol.io/packages/rainbow_csv)
* Rainbow CSV in [IntelliJ IDEA](https://plugins.jetbrains.com/plugin/12896-rainbow-csv/)
* CSVLint for [Notepad++](https://github.com/BdR76/CSVLint)
* rainbow_csv_4_nedit in [NEdit](https://github.com/DmitTrix/rainbow_csv_4_nedit)
* CSV highlighting in [Nano](https://github.com/scopatz/nanorc)
* rainbow-csv package in [Atom](https://atom.io/packages/rainbow-csv)
* rainbow_csv plugin in [gedit](https://github.com/mechatroner/gtk_gedit_rainbow_csv) - doesn't support quoted commas in csv

#### RBQL

* RBQL [website](https://rbql.org/)
* Library and CLI App for [JavaScript](https://www.npmjs.com/package/rbql)
* Library and CLI App for [Python](https://pypi.org/project/rbql/)
* Demo Google Colab IPython [notebook](https://colab.research.google.com/drive/1_cFPtnQUxILP0RE2_DBlqIfXaEzT-oZ6?usp=sharing)

#### Related vim plugins:
Rainbow CSV name and original implementation was significantly influenced by [rainbow_parentheses](https://github.com/kien/rainbow_parentheses.vim) Vim plugin.  

There also exists an old vim syntax file [csv_color](https://vim.sourceforge.io/scripts/script.php?script_id=518) which, despite it's name, can highlight only *.tsv files.  
And, of course, there is [csv.vim](https://github.com/chrisbra/csv.vim)

