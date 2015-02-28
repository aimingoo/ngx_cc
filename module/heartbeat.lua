local function apply(invoke)
	-- client heartbeats
	--	/channel_name/invoke?heartbeat
	invoke.heartbeat = function(route, channel, arg)
		local cluster = route.cluster
		if cluster.worker_initiated then
			route.cc('/_/invoke', { direction='super', args={reportHubPort=cluster.master.port} })
			if cluster.report_clients then
				route.cc('/_/invoke', { direction='workers', args={heartbeat2=true} })
			end
		end
	end

	-- client heartbeats, when report_clients is true
	--	/channel_name/invoke?heartbeat2
	invoke.heartbeat2 = function(route, channel, arg)
		route.cc('/_/invoke', { direction='super', args={reportClient=route.cluster.worker.port} })
	end

	return invoke
end

return {
	apply = function(route)
		-- reset tasks management module
		local Tasks, meta = require("lib.ngx_tasks"), getmetatable(route.tasks)
		if not meta or meta.__index ~= Tasks then
			setmetatable(route.tasks, { __index = Tasks })
			route.tasks.dict = route.shared
		end
		-- task of heartbeat
		route.tasks:push({
			name = 'heartbeats of clients',
			identifier = 'client_heartbeats',
			interval = 60,
			typ = 'preemption',		-- preemption in multi-workers, only once
			callback = function(self)
				route.self('/_/invoke', { args={heartbeat=true} })
			end
		})
		return apply(route.invoke)
	end
}
