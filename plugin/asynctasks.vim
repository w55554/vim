"======================================================================
"
" asynctasks.vim - 
"
" Created by skywind on 2020/01/16
" Last Modified: 2020/01/16 00:50:59
"
"======================================================================

" vim: set noet fenc=utf-8 ff=unix sts=4 sw=4 ts=4 :


"----------------------------------------------------------------------
" internal variables
"----------------------------------------------------------------------
let s:windows = has('win32') || has('win64') || has('win16') || has('win95')
let s:scriptname = expand('<sfile>:p')
let s:scripthome = fnamemodify(s:scriptname, ':h:h')


"----------------------------------------------------------------------
" default values
"----------------------------------------------------------------------

" system identifier
if !exists('g:asynctasks_system')
	let g:asynctasks_system = (s:windows)? 'win' : 'unix'
endif

" local config
if !exists('g:asynctasks_config_name')
	let g:asynctasks_config_name = '.tasks'
endif

" global config in every runtimepath
if !exists('g:asynctasks_rtp_config')
	let g:asynctasks_rtp_config = 'tasks.ini'
endif

" config by vimrc
if !exists('g:asynctasks_tasks')
	let g:asynctasks_tasks = {}
endif

" builtin
if !exists('g:asynctasks_init_tasks')
	let g:asynctasks_init_tasks = 1
endif


"----------------------------------------------------------------------
" internal object
"----------------------------------------------------------------------
let s:private = { 'cache':{}, 'rtp':{}, 'local':{}, 'tasks':{} }
let s:error = ''
let s:index = 0


"----------------------------------------------------------------------
" internal function
"----------------------------------------------------------------------

" display in cmdline
function! s:errmsg(msg)
	redraw | echo '' | redraw
	echohl ErrorMsg
	echom 'Error: ' . a:msg
	echohl NONE
	let s:index += 1
endfunc

" trim leading & trailing spaces
function! s:strip(text)
	return substitute(a:text, '^\s*\(.\{-}\)\s*$', '\1', '')
endfunc

" replace string
function! s:replace(text, old, new)
	let l:data = split(a:text, a:old, 1)
	return join(l:data, a:new)
endfunc

" load ini file
function! s:readini(source, strict)
	if type(a:source) == type('')
		if !filereadable(a:source)
			return -1
		endif
		let content = readfile(a:source)
	elseif type(a:source) == type([])
		let content = a:source
	else
		return -2
	endif
	let sections = {}
	let current = 'default'
	let index = 0
	for line in content
		let t = substitute(line, '^\s*\(.\{-}\)\s*$', '\1', '')
		let index += 1
		if t == ''
			continue
		elseif t =~ '^[;#].*$'
			continue
		elseif t =~ '^\[.*\]$'
			let current = substitute(t, '^\[\s*\(.\{-}\)\s*\]$', '\1', '')
		else
			let pos = stridx(t, '=')
			if pos >= 0
				let key = strpart(t, 0, pos)
				let val = strpart(t, pos + 1)
				let key = substitute(key, '^\s*\(.\{-}\)\s*$', '\1', '')
				let val = substitute(val, '^\s*\(.\{-}\)\s*$', '\1', '')
				if !has_key(sections, current)
					let sections[current] = {}
				endif
				let sections[current][key] = val
			elseif a:strict != 0
				return index
			endif
		endif
	endfor
	return sections
endfunc

" returns nearest parent directory contains one of the markers
function! s:find_root(name, markers, strict)
	let name = fnamemodify((a:name != '')? a:name : bufname(), ':p')
	let finding = ''
	" iterate all markers
	for marker in split(g:projectile#marker, ',')
		if marker != ''
			" search as a file
			let x = findfile(marker, name . '/;')
			let x = (x == '')? '' : fnamemodify(x, ':p:h')
			" search as a directory
			let y = finddir(marker, name . '/;')
			let y = (y == '')? '' : fnamemodify(y, ':p:h:h')
			" which one is the nearest directory ?
			let z = (strchars(x) > strchars(y))? x : y
			" keep the nearest one in finding
			let finding = (strchars(z) > strchars(finding))? z : finding
		endif
	endfor
	if finding == ''
		return (a:strict == 0)? fnamemodify(name, ':h') : ''
	endif
	return fnamemodify(finding, ':p')
endfunc

" find project root
function! s:project_root(name, strict)
	let markers = ['.project', '.git', '.hg', '.svn', '.root']
	if exists('g:asyncrun_rootmarks')
		let markers = g:asyncrun_rootmarks
	endif
	return s:find_root(a:name, markers, a:strict)
endfunc

" change directory in a proper way
function! s:chdir(path)
	if has('nvim')
		let cmd = haslocaldir()? 'lcd' : (haslocaldir(-1, 0)? 'tcd' : 'cd')
	else
		let cmd = haslocaldir()? ((haslocaldir() == 1)? 'lcd' : 'tcd') : 'cd'
	endif
	silent execute cmd . ' '. fnameescape(a:path)
endfunc

" search files upwards
function! s:search_parent(name, cwd)
	let finding = findfile(a:name, a:cwd . '/;', -1)
	let output = []
	for name in finding
		let name = fnamemodify(name, ':p')
		let output += [name]
	endfor
	return output
endfunc

" get absolute path
function! s:abspath(path)
	let f = a:path
	if f =~ "'."
		try
			redir => m
			silent exe ':marks' f[1]
			redir END
			let f = split(split(m, '\n')[-1])[-1]
			let f = filereadable(f)? f : ''
		catch
			let f = '%'
		endtry
	endif
	let f = (f != '%')? f : expand('%')
	let f = fnamemodify(f, ':p')
	if s:windows != 0
		let f = substitute(f, "\\", '/', 'g')
	endif
	if len(f) > 1
		let size = len(f)
		if f[size - 1] == '/'
			let f = strpart(f, 0, size - 1)
		endif
	endif
	return f
endfunc

" read ini
function! s:cache_load_ini(name)
	let name = (stridx(a:name, '~') >= 0)? expand(a:name) : a:name
	let name = s:abspath(name)
	let p1 = name
	if s:windows || has('win32unix')
		let p1 = tr(tolower(p1), "\\", '/')
	endif
	let ts = getftime(name)
	if ts < 0
		let s:error = 'cannot load ' . a:name
		return -1
	endif
	if has_key(s:private.cache, p1)
		let obj = s:private.cache[p1]
		if ts <= obj.ts
			return obj
		endif
	endif
	let config = s:readini(name, 1)
	if type(config) != v:t_dict
		let s:error = 'syntax error in '. a:name . ' line '. config
		return config
	endif
	let s:private.cache[p1] = {}
	let obj = s:private.cache[p1]
	let obj.ts = ts
	let obj.name = name
	let obj.config = config
	let obj.keys = keys(config)
	let home = fnamemodify(name, ':h')
	for sect in obj.keys
		let section = obj.config[sect]
		for key in keys(section)
			let val = section[key]
			let section[key] = s:replace(val, '$(CFGHOME)', home)
		endfor
	endfor
	return obj
endfunc


"----------------------------------------------------------------------
" collect config in rtp
"----------------------------------------------------------------------
function! s:collect_rtp_config() abort
	let names = []
	if g:asynctasks_init_tasks != 0
		let name = s:abspath(s:scripthome . '/tools/default.ini')
		if filereadable(name)
			let names += [name]
		endif
	endif
	for rtp in split(&rtp, ',')
		if rtp != ''
			let path = s:abspath(rtp . '/' . g:asynctasks_rtp_config)
			if filereadable(path)
				let names += [path]
			endif
		endif
	endfor
	let s:private.rtp.ini = {}
	let config = {}
	let s:error = ''
	for name in names
		let obj = s:cache_load_ini(name)
		if s:error == ''
			for key in keys(obj.config)
				let s:private.rtp.ini[key] = obj.config[key]
				let s:private.rtp.ini[key].__name__ = name
				let s:private.rtp.ini[key].__mode__ = "rtp"
			endfor
		else
			call s:errmsg(s:error)
			let s:error = ''
		endif
	endfor
	let config = deepcopy(s:private.rtp.ini)
	for key in keys(g:asynctasks_tasks)
		let config[key] = g:asynctasks_tasks[key]
		let config[key].__name__ = 'vimscript'
		let config[key].__mode__ = 'vimscript'
	endfor
	let s:private.rtp.config = config
	return s:private.rtp.config
endfunc


"----------------------------------------------------------------------
" fetch rtp config
"----------------------------------------------------------------------
function! s:compose_rtp_config(force)
	if (!has_key(s:private.rtp, 'config')) || a:force != 0
		call s:collect_rtp_config()
	endif
	return s:private.rtp.config
endfunc


"----------------------------------------------------------------------
" fetch local config
"----------------------------------------------------------------------
function! s:compose_local_config(path)
	let names = s:search_parent(g:asynctasks_config_name, a:path)
	let config = {}
	for name in names
		let s:error = ''
		let obj = s:cache_load_ini(name)
		if s:error == ''
			for key in keys(obj.config)
				let config[key] = obj.config[key]
				let config[key].__name__ = name
				let config[key].__mode__ = 'local'
			endfor
		else
			call s:errmsg(s:error)
			let s:error = ''
		endif
	endfor
	let s:private.local.config = config
	return config
endfunc


"----------------------------------------------------------------------
" fetch all config
"----------------------------------------------------------------------
function! asynctasks#collect_config(path, force)
	let s:index = 0
	let s:error = ''
	let c1 = s:compose_rtp_config(a:force)
	let c2 = s:compose_local_config(a:path)
	let tasks = {'config':{}, 'names':{}, 'avail':[]}
	for cc in [c1, c2]
		for key in keys(cc)
			let tasks.config[key] = cc[key]
		endfor
	endfor
	for key in keys(tasks.config)
		let parts = split(key, ':')
		let name = (len(parts) >= 1)? parts[0] : ''
		let system = (len(parts) >= 2)? parts[1] : ''
		if system == ''
			let tasks.avail += [key]
			let tasks.names[key] = 1
		elseif system == g:asynctasks_system
			let tasks.avail += [key]
			let tasks.names[key] = 1
		endif
	endfor
	let s:private.tasks = tasks
	return (s:index == 0)? 0 : -1
endfunc


"----------------------------------------------------------------------
" get project root
"----------------------------------------------------------------------
function! asynctasks#project_root(name, ...)
	return s:project_root(a:name, (a:0 == 0)? 0 : (a:1))
endfunc


"----------------------------------------------------------------------
" split section name:system
"----------------------------------------------------------------------
function! asynctasks#split(name)
	let parts = split(name, ':')
	let name = (len(parts) >= 1)? parts[0] : ''
	let system = (len(parts) >= 2)? parts[1] : ''
	return [name, system]
endfunc


"----------------------------------------------------------------------
" format table
"----------------------------------------------------------------------
function! asynctasks#tabulify(rows)
	let content = []
	let rows = []
	let nrows = len(a:rows)
	let ncols = 0
	for row in a:rows
		if len(row) > ncols
			let ncols = len(row)
		endif
	endfor
	if nrows == 0 || ncols == 0
		return content
	endif
	let sizes = repeat([0], ncols)
	let index = range(ncols)
	for row in a:rows
		let newrow = deepcopy(row)
		if len(newrow) < ncols
			let newrow += repeat([''], ncols - len(newrow))
		endif
		for i in index
			let size = len(newrow[i])
			let sizes[i] = (sizes[i] < size)? size : sizes[i]
		endfor
		let rows += [newrow]
	endfor
	for row in rows
		let ni = []
		for i in index
			let x = row[i]
			let size = len(x)
			if len(x) < sizes[i]
				let x = x . repeat(' ', sizes[i] - size)
			endif
			let ni += [x]
		endfor
		let text = join(ni, '  ')
		let content += [text]
	endfor
	return content
endfunc


"----------------------------------------------------------------------
" display table
"----------------------------------------------------------------------
function! s:print_table(rows)
	let content = asynctasks#tabulify(a:rows)
	for line in content
		echo ' '. line
	endfor
endfunc


"----------------------------------------------------------------------
" format parameter
"----------------------------------------------------------------------
function! s:task_option(task)
	let task = a:task
	let opts = {}
	if has_key(task, 'cwd')
		let opts.cwd = task.cwd
	endif
	if has_key(task, 'mode')
		let opts.mode = task.mode
	endif
	if has_key(task, 'raw')
		let opts.raw = task.raw
	endif
	if has_key(task, 'save')
		let opts.save = task.save
	endif
	if has_key(task, 'errorformat')
		let opts.errorformat = task.errorformat
		if task.errorformat == ''
			let opts.raw = 1
		endif
	endif
	if has_key(task, 'strip')
		let opts.strip = task.strip
	endif
	for key in ['pos', 'rows', 'cols']
		if has_key(task, key)
			let opts[key] = task[key]
		endif
	endfor
	return opts
endfunc


"----------------------------------------------------------------------
" run task
"----------------------------------------------------------------------
function! asynctasks#run(bang, taskname, path)
	let path = (a:path == '')? expand('%:p') : a:path
	if asynctasks#collect_config(path, 1) != 0
		return -1
	endif
	let s:error = ''
	let tasks = s:private.tasks
	if !has_key(tasks.names, a:taskname)
		call s:errmsg('not find task [' . a:taskname . ']')
		return -2
	endif
	let task = tasks.config[a:taskname]
	let ininame = task.__name__
	let source = 'task ['. a:taskname . '] from ' . ininame
	if !has_key(task, 'command') || task.command == ''
		call s:errmsg('not find command in ' . source)
		return -3
	endif
	if exists(':AsyncRun') == 0
		call s:errmsg('asyncrun is not installed')
		return -4
	endif
	let opts = s:task_option(task)
	call asyncrun#run(a:bang, opts, task.command)
	return 0
endfunc


"----------------------------------------------------------------------
" list tasks
"----------------------------------------------------------------------
function! s:task_list(path)
	let path = (a:path == '')? expand('%:p') : a:path
	if asynctasks#collect_config(path, 1) != 0
		return -1
	endif
	let tasks = s:private.tasks
	let rows = []
	let rows += [['Task', 'Type', 'Config']]
	let rows += [['----', '----', '------']]
	for task in tasks.avail
		let item = tasks.config[task]
		let rows += [[task, item.__mode__, item.__name__]]
	endfor
	call s:print_table(rows)
endfunc


"----------------------------------------------------------------------
" command AsyncTask
"----------------------------------------------------------------------
function! asynctasks#cmd(bang, ...)
	let taskname = (a:0 >= 1)? (a:1) : ''
	if taskname == ''
		call s:errmsg('empty task name, use ":AsyncTask -h" for help')
		return -1
	elseif taskname == '-h'
		echo 'usage:  :AsyncTask <operation>'
		echo 'operations:'
		echo '    :AsyncTask {taskname}      - run specific task'
		echo '    :AsyncTask -l              - list tasks'
		echo '    :AsyncTask -h              - show this help'
		return 0
	elseif taskname == '-l'
		call s:task_list('')
		return 0
	endif
	call asynctasks#run(a:bang, taskname, '')
endfunc


"----------------------------------------------------------------------
" commands
"----------------------------------------------------------------------

command! -bang -nargs=* AsyncTask
			\ call asynctasks#cmd('<bang>', <q-args>)



"----------------------------------------------------------------------
" benchmark
"----------------------------------------------------------------------
function! asynctasks#timing()
	let ts = reltime()
	" call s:collect_rtp_config()
	call asynctasks#collect_config('.', 1)
	let tt = reltimestr(reltime(ts))
	echo s:private.rtp.config
	return tt
endfunc



