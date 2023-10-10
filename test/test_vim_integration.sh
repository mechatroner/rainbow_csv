#!/usr/bin/env bash

node_version=$( node --version 2> /dev/null )
rc=$?
if [ "$rc" != 0 ] || [ -z "$node_version" ] ; then
    echo "WARNING! Node.js was not found. Skipping integration tests"  1>&2
    # FIXME run reduced tests without node in this case
    exit 1
fi


cleanup_tmp_files() {
    rm random_ut.csv 2> /dev/null
    rm movies.tsv.py.rs 2> /dev/null
    rm movies.tsv.js.rs 2> /dev/null
    rm movies.tsv.system_py.py.rs 2> /dev/null
    rm movies.tsv.system_py.js.rs 2> /dev/null
    rm university_ranking.rs.tsv 2> /dev/null
    rm vim_unit_tests.log 2> /dev/null
    rm vim_debug.log 2> /dev/null
    rm movies_small.tsv.csv 2> /dev/null
    rm movies_small.tsv.csv.tsv 2> /dev/null
}


vim=vim

while test ${#} -gt 0
do
  if [ $1 == "--vim" ]; then
      shift
      vim=$1
      shift
  else
      echo "Error. Unknown parameter: $1" 1>&2
      shift
      exit 1
  fi
done


echo "Starting vim integration tests"

cleanup_tmp_files

# We need random_ut.csv file in vim unit tests
PYTHONPATH="../rbql_core:$PYTHONPATH" python ../rbql_core/test/test_csv_utils.py --create_random_csv_table random_ut.csv

$vim -s integration_tests.vim -V0vim_debug.log -u test_vimrc

errors=$( cat vim_debug.log | grep '^E[0-9][0-9]*' | wc -l )
total=$( cat vim_unit_tests.log | wc -l )
started=$( cat vim_unit_tests.log | grep 'Starting' | wc -l )
finished=$( cat vim_unit_tests.log | grep 'Finished' | wc -l )
fails=$( cat vim_unit_tests.log | grep 'FAIL' | wc -l )

if [ $errors != 0 ] || [ ! -e vim_debug.log ] ; then
    echo "Warning: some errors were detected during vim integration testing, see vim_debug.log:"  1>&2
    cat vim_debug.log
    exit 1
fi

if [ $total != 13 ] || [ $started != $finished ] || [ $fails != 0 ] ; then
    echo "FAIL! Integration tests failed: see vim_unit_test.log"  1>&2
    exit 1
fi

md5sum_movies_csv_canon="bb13547839020c33ba0da324fd0bb197"
md5sum_movies_tsv_canon="2a8016ac2cb05f52a1fd391a909112f5"

md5sum_test_1=($( md5sum movies.tsv.py.rs ))
md5sum_test_2=($( md5sum movies.tsv.js.rs ))
md5sum_test_3=($( md5sum movies.tsv.system_py.py.rs ))
md5sum_test_4=($( md5sum movies.tsv.system_py.js.rs ))
md5sum_update=($( md5sum university_ranking.rs.tsv ))
md5sum_movies_csv_test=($( md5sum movies_small.tsv.csv ))
md5sum_movies_tsv_test=($( md5sum movies_small.tsv.csv.tsv ))

md5sum_canonic=($( md5sum canonic_integration_1.tsv ))
sanity_len=$( printf "$md5sum_canonic" | wc -c )

if [ "$sanity_len" != 32 ] || [ "$md5sum_test_1" != $md5sum_canonic ] || [ "$md5sum_test_2" != $md5sum_canonic ] || [ "$md5sum_test_3" != $md5sum_canonic ] || [ "$md5sum_test_4" != $md5sum_canonic ] ; then
    echo "FAIL! Integration tests failed: md5sums"  1>&2
    exit 1
fi

if [ "$md5sum_movies_csv_canon" != "$md5sum_movies_csv_test" ] || [ "$md5sum_movies_tsv_canon" != "$md5sum_movies_tsv_test" ] ; then
    echo "FAIL! Integration tests failed: md5sums for movies_small"  1>&2
    exit 1
fi

if [ "$md5sum_update" != "d2681d3b6e4701c2e7d22ffddd299aaa" ] ; then
    echo "FAIL! Update integration tests failed: md5sums"  1>&2
    exit 1
fi


cleanup_tmp_files

echo "Finished vim integration tests"
