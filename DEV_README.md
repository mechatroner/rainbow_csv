# Testing

### Running unit tests only
```
echo "" > vim_debug.log && vim -s unit_tests_only.vim -V0vim_debug.log -u test_vimrc && cat vim_debug.log
```

Apparently there is a glitch with the integration tests that may cause the keyboard cursor to spontaneously move down.


# Other
### Vim Docs
To re-generate help tags and check the new adjusted version of the docs, run `:helptags /path/to/rainbow_csv/doc`

