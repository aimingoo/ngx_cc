-- a minimum posix system module
--
-- from: https://github.com/nyfair/freeimagerip/blob/master/wrapper/luajit-ffi/lua/fsposix.lua
--		 https://github.com/justincormack/ljsyscall/blob/master/syscall/bsd/ffi.lua
-- fixed: aimingoo@wandoujia.com
--
-- The file is in public domain
-- nyfair (nyfair2012@gmail.com)

local function mktype(tp, x) if ffi.istype(tp, x) then return x else return tp(x) end end
local function istype(tp, x) if ffi.istype(tp, x) then return x else return false end end

local ffi = require 'ffi'
local def = [[
	int mkdir(const char*, mode_t mode);
	int rmdir(const char *pathname);
	int chmod(const char *path, mode_t mode);
	pid_t getppid(pid_t pid);
	pid_t getpgid(pid_t pid);
]]

local abi = ffi.os:lower() -- + ffi.abi("32bit")
if abi == 'osx' or abi == 'freebsd' then
	def = 'typedef uint16_t mode_t;\n' .. def;
else
	def = 'typedef uint32_t mode_t;\n' .. def;
end
def = 'typedef int32_t pid_t;\n' .. def;

ffi.cdef(def)

local posix = {}

function posix.ls(pattern)
	local files = {}
	local output = assert(io.popen('ls '..pattern:gsub(' ', '\\ ')))
	for line in output:lines() do
		table.insert(files, line)
	end
	return files
end

function posix.cp(src, dest)
	-- @see: http://stackoverflow.com/questions/16367524/copy-csv-file-to-new-file-in-lua
	--	os.execute("cp '" .. src .. "' '" .. dst .. "'"')
	local infile, outfile = io.open(src, "r"), io.open(dest, "w")
	outfile:write(infile:read("*a"))
	infile:close()
	outfile:close()
end

-- local octal = function (s) return tonumber(s, 8) end
-- local mode_t = ffi.typeof('mode_t')
-- local mode = octal('0777')
function posix.md(dst, mod)
	return ffi.C.mkdir(dst, mod or 493) --0755
end

function posix.chmod(dst, mod)
	return ffi.C.chmod(dst, mod or 493) --0755
end

function posix.rd(dst)
	-- os.execute('rm -rf '..normalize(dst:gsub(' ', '\\ ')))
	return ffi.C.mkdir(dst)
end

-- check file exist
function posix.exist(name)
	local f = io.open(name, "r")
	return f ~= nil and (f:close() or true) or false
end

-- read small file to string, blocking
function posix.all(name)
	local f = io.open(name, "rb")
	local content = f:read('*a')
	f:close()
	return content
end

-- get all lines from a file
--	1) returns an empty list/table if the file does not exist
function posix.lines(name)
	local lines = {}
	for line in io.lines(name) do
		table.insert(lines, line)
	end
	return lines
end

-- save all lines to a file, <lines> is table/string, or any value as string.
--	1) no returns
function posix.save(name, lines)
	local file = io.open(name, 'w+')
	file:write(type(lines)=='table' and table.concat(lines, '') or tostring(lines))
	file:close()
end

-- http://stackoverflow.com/questions/2833675/using-lua-check-if-file-is-a-directory
--	1) WINDOWS unsupport
local function _isdir(path)
    local f = io.open(path, "r")
    if (f ~= nil) then
    	local ok, err, code = f:read(1)
    	f:close()
    	return code == 21	-- exist, cant read as file (is directory, maybe)
    end
    return false	-- no exist
end

local function _mkdir(path)
	-- if WINDOWS and path:find('^%a:/*$') then return true end
	if not _isdir(path) then
		local parent = path:match('(.+)/[^/]+$')
		if parent and not _mkdir(parent) then
			return nil, 'cannot create '..parent
		else
			return (posix.md(path) == 0)
		end
	else
		return true
	end
end

-- make diretory with fullpath
posix.mkdir = _mkdir;
-- posix.mkdir = function(path)
-- 	-- if WINDOWS then path = path:gsub('\\','/') end
-- 	return _mkdir(path)
-- end

function posix.ppid(pid)
	return ffi.C.getppid(pid)
end

function posix.pgid(pid)
	return ffi.C.getpgid(pid)
end

return posix