syntax match column0 /.\{-}\(  *\|$\)/ nextgroup=column1
syntax match column1 /.\{-}\(  *\|$\)/ nextgroup=column2
syntax match column2 /.\{-}\(  *\|$\)/ nextgroup=column3
syntax match column3 /.\{-}\(  *\|$\)/ nextgroup=column4
syntax match column4 /.\{-}\(  *\|$\)/ nextgroup=column5
syntax match column5 /.\{-}\(  *\|$\)/ nextgroup=column6
syntax match column6 /.\{-}\(  *\|$\)/ nextgroup=column7
syntax match column7 /.\{-}\(  *\|$\)/ nextgroup=column8
syntax match column8 /.\{-}\(  *\|$\)/ nextgroup=column9
syntax match column9 /.\{-}\(  *\|$\)/ nextgroup=column0
syntax match startcolumn /^ *.\{-}\(  *\|$\)/ nextgroup=column1
