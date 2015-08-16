local JSON = require('lib.JSON')

local function apply(invoke)
	local function HOST(node)
		return node.host .. ':' .. (node.port or '80')
	end

	-- get services status (with clients deep discovery)
	--	/channel_name/invoke?getServiceStat
	invoke.getServiceStat = function(route, channel, arg)
		local clients
		if not arg.selfOnly then
			local r_status, r_resps = route.cc('/_/invoke', route.optionAgain({ direction = 'clients' }))
			clients = {}
			for _, resp in ipairs(r_resps) do
				if (resp.status == ngx.HTTP_OK) then
					local ok, result = pcall(JSON.decode, resp.body)
					clients[resp.client] = ok and result or
						{ super = '-', ports = '-', routePort = '-', clients = {} }
				end
				if clients[resp.client] then
					clients[resp.client].service = resp.client
				end
			end
		end

		local key_registed_workers = 'ngx_cc.'..channel..'.registed.workers'
		local shared, cluster = route.shared, route.cluster
		ngx.say(JSON.encode({
			super = (not route.isRoot()) and HOST(cluster.super) or nil,
			service = HOST(cluster.master),
			ports = shared:get(key_registed_workers),
			routePort = cluster.router.port,
			clients = clients
		}))
		ngx.exit(ngx.HTTP_OK)
	end

	-- transfer channel's super to new server, invoke and process by per-workers
	--	/channel_name/invoke?transferServer=ip:port
	--	1) for per-workers, change instance's cluster.super only
	invoke.transferServer = function(route, channel, arg)
		if route.isInvokeAtPer() then
			route.transfer(arg.transferServer)
		end
		ngx.say('Okay.')
		ngx.exit(ngx.HTTP_OK)
	end

	return invoke
end

return {
	apply = function(route)
		return apply(route.invoke)
	end
}