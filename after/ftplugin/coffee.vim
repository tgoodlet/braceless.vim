if exists('b:did_braceless_ftplugin') | finish | endif
let b:did_braceless_ftplugin = 1

let s:cpo_save = &cpo
set cpo&vim

" Stub

let &cpo = s:cpo_save
unlet s:cpo_save
