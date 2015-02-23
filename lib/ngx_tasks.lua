-----------------------------------------------------------------------------
-- Tasks management module for lua in nginx
-- Author: chaihaotian@wandoujia.com, aimingoo@wandoujia.com
-- Copyright (c) 2014.12
--
-- Usage:
--	tasks = require('ngx_tasks')
--	tasks.dict = 'your_shared_dict_config_in_<nginx.conf>'
--	tasks:push(rule)
--		...
--	tasks:run()
-----------------------------------------------------------------------------

local function hasPreempt(shared, version, preemptionName)
	local preempted, memoryVersion = true, shared:get(preemptionName)

	if memoryVersion == nil then
		if shared:add(preemptionName, version, 86400) then
			return preempted
		end
		memoryVersion = shared:get(preemptionName) or version
	end

	if memoryVersion < version then
		if shared:add(preemptionName..'_'..memoryVersion, version, 3600) then
			return shared:set(preemptionName, version, 86400)
		else
			local newVersion = shared:get(preemptionName..'_'..memoryVersion) or version
			if newVersion < version then
				if shared:set(preemptionName, version, 86400) then
					return preempted
				end
				ngx.log(ngx.ALERT, 'Error in hasPreempt(), version/newVersion/memoryVersion: ' ..
					table.concat({version, newVersion, memoryVersion}, '/'))
			end
		end
	end

	return not preempted
end

local Tasks = {
	dict = 'PreemptionTasks',

	run = function(self)
		if type(self.dict) == 'string' then
			self.dict = assert(ngx.shared[self.dict], 'access shared dictionary: '..self.dict)
		end
		local now = os.time()
		for _, task in ipairs(self) do
			if not task.last_execute or (task.last_execute + task.interval < now) then
				task.last_execute = now
				if ((task.typ == 'normal') or
					(task.typ == 'preemption' and hasPreempt(self.dict, self:keys(task, now)))) then
					if not task.filter or task:filter() then
						task:callback()
					end
				end
			end
		end
	end,

	push = function(self, rule)
		table.insert(self, rule)
	end,

	remove = function(self, id)
		for i = #self, 1, -1 do
			if self[i].identifier == id then
				table.remove(self, i)
			end
		end
	end,

	keys = function(self, task, now)
		local d = os.date('*t', now)
		local second = now - os.time{year=d.year, month=d.month, day=d.day, hour=0}
		return math.floor(second/task.interval), task.identifier .. 'Preemption.' .. os.date('%Y%m%d', now)
	end
}

return Tasks