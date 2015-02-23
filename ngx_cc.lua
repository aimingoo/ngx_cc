-----------------------------------------------------------------------------
-- NGX_CC v1.0.0
-- Author: aimingoo@wandoujia.com
-- Copyright (c) 2015.02
-- Descition:　a framework of Nginx Communication Cluster. reliable
--	dispatch/translation　messages in nginx nodes and processes.
--
-- Usage:
--	ngx_cc = require('ngx_cc')
--	rotue = ngx_cc:new('kada')	-- work with 'kada' channel
--	route.cc('/kada/invoke', 'master')
--	  ..
-- instance methods:
--	communication functions: route.cc(), route.cast(), route.self(), route.remote()
--	helper functions: route.isRoot(), route.isInvokeAtMaster()
-- global methods(instance inherited):
--	ngx_cc.say()
--  ngx_cc.optionAgain() and ngx_cc.optionAgain2()
-- next is index of ngx_cc
--	ngx_cc.invokes(channelName)
--	ngx_cc.channels
-----------------------------------------------------------------------------

-- debugging
local function ngx_log(...)
	return ngx.log(...)
end

-- core methods
local ngx_cc_core = require('module.ngx_cc_core')

-- route framework
local R = {
	tasks = {},
	channels = {},

	-- the options:
	--	host 		: current nginx host ip, default is inherited from ngx_cc.cluster.master.host, or '127.0.0.1'
	--	port 		: current nginx listen port, invalid with <manual> initializer only, and deault is '80'
	--	dict 		: shared dictionary name in nginx.conf, default is <channel>..'_dict'
	--	initializer : manual/automatic, default is automatic
	new = function(self, channel, options)
		function clone(src, dest)
			dest = dest or {};
			for name, value in pairs(src) do
				dest[name] = value
			end
			return dest
		end
		local R, options = self, options or {}
		local host = options.host or R.cluster.master.host or '127.0.0.1'
		local c_dict = options and options.dict or channel..'_dict'
		local cluster = {
			super  = setmetatable({}, {__index=R.cluster.super}),
			master = setmetatable({ host = (R.cluster.master.host ~= host and host or nil)}, {__index=R.cluster.master}),
			router = setmetatable({ host = (R.cluster.router.host ~= host and host or nil)}, {__index=R.cluster.router}),
			worker = { host = host },
			worker_initiated = false
		}
		local instance = {
			tasks = {},
			invoke = clone(ngx_cc_core.kernal_actions),
			shared = assert(ngx.shared[c_dict], "access shared dictionary: " .. c_dict),
			cluster = cluster
		}

		-- cc(Cluster Communications) for per-instance
		-- support opt.directions:
		--	'super'  : 1:1	send to super node, the super is parent node.
		--	'master' : 1:1	send to router process from any worker
		--	'workers': 1:*	send to all workers
		--	'clients': 1:*	send to all clients
		local c_patt, c_path = '^/_/', '/'..channel..'/'
		local c_patt2, c_path2 = '^/'..channel..'/[^/%?]+', '/'..channel..'/cast'
		instance.cc = function(url, opt)
			local opt = (type(opt) == 'string') and { direction = opt } or opt or R.optionAgain()
			if opt.method == nil then
				opt.method = ngx.HTTP_GET
			elseif type(opt.method) == 'string' then
				opt.method = ngx['HTTP_'..opt.method]
			end

			if ((opt.direction == 'super' and instance.isRoot()) or
				(opt.direction == 'master' and not cluster.worker_initiated)) then
				opt.direction = 'skip'
			elseif not opt.direction then
				opt.direction =  cluster.worker_initiated and 'master' or 'skip'
			end

			local addr = string.match(url, '^[^/]*//[^/]+')
			local uri = string.sub(url, string.len(addr or '')+1)
			local uri2 = uri:gsub(c_patt, c_path, 1):gsub(c_patt2, c_path2, 1);
			local r_status, r_resps = true, {}

			if opt.direction == 'master' then
				local opt2 = setmetatable({
					vars = {
						cc_host = cluster.router.host,
						cc_port = cluster.router.port
					}
				}, {__index=opt});

				local resp = ngx.location.capture(uri2, opt2);
				r_status = resp.status == ngx.HTTP_OK
				r_resps = { resp }

				local fmt = 'Cast from port %s to master, ' .. (r_status and 'done.' or 'error with status %d.')
				ngx_log(ngx.ALERT, string.format(fmt, cluster.worker.port, resp.status))
			elseif opt.direction == 'super' then
				local opt2 = setmetatable({
					vars = {
						cc_host = cluster.super.host,
						cc_port = cluster.super.port
					}
				}, {__index=opt})

				local resp = ngx.location.capture(uri2, opt2)
				r_status = resp.status == ngx.HTTP_OK
				r_resps = { resp }

				local fmt = 'Cast from port %s to super, ' .. (r_status and 'done.' or 'error with status %d.')
				ngx_log(ngx.ALERT, string.format(fmt, cluster.worker.port, resp.status))
			elseif opt.direction == 'workers' then
				local reqs, ports, registedWorkers = {}, {}, instance.shared:get('ngx_cc.registed.workers') or ''
				for port, opt2 in string.gmatch(registedWorkers, '(%d+),?') do
					opt2 = setmetatable({
						vars = {
							cc_host = cluster.master.host,
							cc_port = port
						}
					}, {__index=opt});
					table.insert(reqs, { uri2, opt2 });
					table.insert(ports, port);
				end

				if #ports > 0 then
					local resps, errPorts = { ngx.location.capture_multi(reqs) }, {}
					for i, resp in ipairs(resps) do
						if resp.status ~= ngx.HTTP_OK then
							table.insert(errPorts, ports[i])
						end
						resp.port = ports[i]
					end
					r_status = #errPorts == 0
					r_resps = resps

					local fmt = 'Cast from port %s to workers: %d/%d, ' .. (r_status and 'done.' or 'and no passed ports: %s.')
					ngx_log(ngx.ALERT, string.format(fmt, cluster.worker.port, #reqs, #resps, table.concat(errPorts, ',')))
				end
			elseif opt.direction == 'clients' then
				local reqs, clients, registedClients = {}, {}, instance.shared:get('ngx_cc.registed.clients') or ''
				for client, port, opt2 in string.gmatch(registedClients, '([^:,]+)([^,]*),?') do
					opt2 = setmetatable({
						vars = {
							cc_host = client,
							cc_port = string.sub(port or '', 2)
						}
					}, {__index=opt})
					table.insert(reqs, { uri2, opt2 });
					table.insert(clients, client..port);
				end

				if #clients > 0 then
					local resps, errClients = { ngx.location.capture_multi(reqs) }, {}
					for i, resp in ipairs(resps) do
						if resp.status ~= ngx.HTTP_OK then
							table.insert(errClients, clients[i])
						end
						resp.client = clients[i]
					end
					r_status = #errClients == 0
					r_resps = resps

					local fmt = 'Cast from port %s to clients: %d/%d, ' .. (r_status and 'done.' or 'and no passed clients: %s.')
					ngx_log(ngx.ALERT, string.format(fmt, cluster.worker.port, #reqs, #resps, table.concat(errClients, ',')))
				end
			end

			return r_status, r_resps
		end

		-- cast to all workers (with current worker)
		instance.cast = function(url, opt)
			return instance.cc(url, R.optionAgain('workers', opt))
		end

		-- cast to self, it's warp of ngx.location.capture() only
		instance.self = function(url, opt)
			local url2 = url:gsub(c_patt, c_path, 1);
			local resp = ngx.location.capture(url2, opt);
			-- ngx_log(ngx.ALERT, 'Cast to self: ' .. (r_status and 'done.' or 'and no passed.'))
			return resp.status == ngx.HTTP_OK, { resp }
		end

		-- cast to remote, RPC
		instance.remote = function(url, opt)
			local addr = string.match(url, '^[^/]*//[^/]+')
			local uri = string.sub(url, string.len(addr or '')+1)
			assert(addr, 'need full remote url')
			local uri2 = c_path2 .. uri
			local resp = ngx.location.capture(uri2, setmetatable({
				vars = {
					cc_host, cc_port = string.match(addr, '^[^/]*//([^:]+):?(.*)')
				}
			}, {__index=opt}));
			-- local fmt = 'Hub from port %s to remote: %s, ' .. (r_status and 'done.' or 'error with status %d.')
			-- ngx_log(ngx.ALERT, string.format(fmt, cluster.worker.port, addr, resp.status))
			return resp.status == ngx.HTTP_OK, { resp }
		end

		-- check current node is root
		instance.isRoot = function()
			local master, su = cluster.master, cluster.super
			return not su or (su.host == master.host and su.port == master.port)
		end

		-- check current worker is master, else false will cast to 'master' with full invoke data
		instance.isInvokeAtMaster = function()
			if cluster.worker.port ~= cluster.router.port then
				return false, instance.cc(ngx.var.uri);
			else
				return true
			end
		end

		-- channel initiatation
		local kernal = ngx_cc_core.kernal_initializer
		local initializer = kernal[options.initializer or 'automatic'] or kernal.automatic
		initializer(instance, cluster, channel, options)

		R.channels[channel] = instance
		return setmetatable(instance, {__index=function(_, key)
			local disabled = {channels = true, invokes = true}
			return not disabled[key] and R[key] or nil
		end})
	end
}

-- option base current worker's request/context/vars/...
function R.optionAgain(direction, opt)
	local opt = opt or {
		method 	= ngx.req.get_method(),
		args 	= ngx.req.get_uri_args(),
		body 	= ngx.req.get_body_data()
	}
	if direction and direction.args and opt.args then
		for key, value in pairs(opt.args) do
			if direction.args[key] == nil then
				direction.args[key] = value
			end
		end
	end
	return (direction == nil) and opt or setmetatable(
		type(direction) == 'table' and direction or { direction = tostring(direction) },
		{ __index = opt }
	)
end

-- optionAgain() with force_mix support
function R.optionAgain2(direction, opt, force_mix_into_current)
	return R.optionAgain(direction, force_mix_into_current and R.optionAgain(opt) or opt)
end

-- simple say() all responses body for R.cc() result
function R.say(r_status, r_resps)
	for _, resp in ipairs(r_resps) do
		if (resp.status == ngx.HTTP_OK) then
			ngx.say(resp.body)
		end
	end
end

local function defaultInvoker(route, channel, arg)
	for key, action in pairs(route.invoke or {}) do
		if arg[key] then
			return action(route, channel, arg)
		end
	end
end

function R.invokes(channel, master_only)
	local route = R.channels[channel]
	if route then
		-- local no_redirected, r_status, r_resps = unpack(master_only and {route.isInvokeAtMaster()} or {true})
		local no_redirected, r_status, r_resps = true
		if master_only then
			no_redirected, r_status, r_resps = route.isInvokeAtMaster()
		end
		if no_redirected then
			local invoker = type(route.invoke) == 'function' and route.invoke or defaultInvoker
			invoker(route, channel, ngx.req.get_uri_args())
		else
			R.say(r_status, r_resps)
		end
	else
		ngx.status = 403
		ngx.say("URL include unknow channel.")
		ngx.exit(ngx.OK)
	end
	-- ngx.log(ngx.ALERT, table.concat({'', channel, ngx.var.cc_host, ngx.var.cc_port, ''}, '||'))
end

-- base struct for multi-workers sub-system
R.cluster = {
	super =  { host='127.0.0.1', port='80' },	-- cc:super
	router = { host='127.0.0.1' },				-- cc:master
	master = { host='127.0.0.1' },				-- cc:workers, use <master.host> only
}
R.cluster.worker = R.cluster.master

return R