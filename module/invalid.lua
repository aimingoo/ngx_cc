local Valider = require('lib.Valider')

local function apply(invoke)
	local checker = Valider:new({
		maxContinuous = 5,	-- continuous invalid 5 times, or
		maxTimes = 10,		-- invalid 10 times in 5 seconds
		maxSeconds = 5,
	})

	-- the worker is invalid, call from local with ngx_cc to-'master' always
	--	/channel_name/invoke?invalidWorker=port
	invoke.invalidWorker = function(route, channel, arg)
		local port, t = arg.invalidWorker, arg.t or false
		if checker:invalid(channel..'.localhost:'..port, t) then
			local shared, key_registed_workers = route.shared, 'ngx_cc.'..channel..'.registed.workers'
			local workers, registedWorkers = {}, shared:get(key_registed_workers)
			for p in string.gmatch(registedWorkers, "(%d+),?") do
				if p ~= port then
					table.insert(workers, p)
				end
			end
			shared:set(key_registed_workers, table.concat(workers, ','))
		end
	end

	-- the client is invalid, call from local with ngx_cc to-'master' always
	--	/channel_name/invoke?invalidClient=ip:port
	invoke.invalidClient = function(route, channel, arg)
		local client, t = arg.invalidClient, arg.t or false
		if checker:invalid(channel..'.'..client, t) then
			local shared, key_registed_clients = route.shared, 'ngx_cc.'..channel..'.registed.clients'
			local clients, registedClients = {}, shared:get(key_registed_clients)
			local c, p = string.match(client, '([^:,]+)([^,]*)')
			for client, port in string.gmatch(registedClients, '([^:,]+)([^,]*),?') do
				if c ~= client then
					table.insert(clients, client .. port)
				end
			end
			shared:set(key_registed_clients, table.concat(clients, ','))
		end
	end

	return invoke
end

return {
	apply = function(route)
		return apply(route.invoke)
	end
}