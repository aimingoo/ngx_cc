--
-- fake lua-process, lua native version for getppid() only
--	0) binary version: https://github.com/mah0x211/lua-process
--	1) base https://github.com/Kami/luvit-process-info
--	2) need procfs support
--
local process = { getppid = function(_, pid)
	-- @see https://github.com/Kami/luvit-process-info/blob/master/lib/util.lua
	local Utils = {
		split = function(str, pattern)
			pattern = pattern or "[^%s]+"
			if pattern:len() == 0 then pattern = "[^%s]+" end
			local parts = {__index = table.insert}
			setmetatable(parts, parts)
			str:gsub(pattern, parts)
			setmetatable(parts, nil)
			parts.__index = nil
			return parts
		end,
		trim = function(s)
			return s:find'^%s*$' and '' or s:match'^%s*(.*%S)'
		end
	}

	-- @see http://stackoverflow.com/questions/10386672/reading-whole-files-in-lua
	local fs = {
		readFileSync = function(fileName)
			local f, content, length = io.open(fileName, "r"), "", 0
			if f then
				content = f:read("*all")
				io.close(f)
			end
			return content
		end
	}

	local procPath = '/proc'	-- IT'S DEFAULT_PROC_PATH
	local filePath = table.concat({procPath, tostring(pid), 'status'}, '/')
	local content = fs.readFileSync(filePath)
	local lines, status = Utils.split(content, '[^\n]+'), {}
	for index, line in ipairs(lines) do
		pair = Utils.split(line, '[^:]+')
		status[pair[1]] = Utils.trim(pair[2])
	end
	return tonumber(status['PPid'])
end }

return process
