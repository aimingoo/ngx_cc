local JSON = require('lib.JSON')

local function apply(invoke)
	local function HOST(node)
		return node.host .. ':' .. (node.port or '80')
	end

	-- get services status (with clients deep discovery)
	--	/channel_name/invoke?getServiceStat
	invoke.getServiceStat = function(route, channel, arg)
		local clients = {}
		local r_status, r_resps = route.cc('/_/invoke', route.optionAgain({ direction = 'clients' }))
		for _, resp in ipairs(r_resps) do
			clients[resp.client] = (resp.status == ngx.HTTP_OK) and JSON:decode(resp.body) or false;
			if clients[resp.client] then
				clients[resp.client].service = resp.client
			end
		end

		local shared, cluster, key = route.shared, route.cluster, 'ngx_cc.registed.workers'
		ngx.say(JSON:encode({
			super = (not route.isRoot()) and HOST(cluster.super) or nil,
			service = HOST(cluster.master),
			ports = shared:get(key),
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