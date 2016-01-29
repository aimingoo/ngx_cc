-----------------------------------------------------------------------------
-- NGX_CC v2.1.1
-- Author: aimingoo@wandoujia.com
-- Copyright (c) 2015.02-2015.10
-- Descition:　a framework of Nginx Communication Cluster. reliable
--	dispatch/translation　messages in nginx nodes and processes.
--
-- Usage:
--	ngx_cc = require('ngx_cc')
--	route = ngx_cc:new('kada')	-- work with 'kada' channel
--	route.cc('/kada/invoke', 'master')
--	  ..
-- instance methods:
--	communication functions: route.cc(), route.cast(), and inherited from ngx_cc: all/remote/self, ...
--	helper functions: route.isRoot(), route.isInvokeAtMaster(), route.isInvokeAtPer()
-- global methods(instance inherited):
--	ngx_cc.say(), ngx_cc.all(), ngx_cc.remote(), ngx_cc.self(), ngx_cc.transfer()
--  ngx_cc.optionAgain() and ngx_cc.optionAgain2()
-- these are index of ngx_cc
--	ngx_cc.invokes(channelName)
--	ngx_cc.channels
--
-- History:
--	2015.11.04	release v2.1.1, channel_resources as native resource management
--	2015.10.22	release v2.1.0, publish NGX_CC node as N4C resources
--	2015.08.13	release v2.0.0, support NGX_4C programming architecture
--	2015.02		release v1.0.0
-----------------------------------------------------------------------------

-- debugging
local function ngx_log(...)
	return ngx.log(...)
end

-- core methods
local ngx_cc_core = require('module.ngx_cc_core')

-- with status >= 200 (ngx.HTTP_OK) and status < 300 (ngx.HTTP_SPECIAL_RESPONSE) for successful quits
--	*) see: https://www.nginx.com/resources/wiki/modules/lua/#ngx-exit
local HTTP_SUCCESS = function(status)
	return status >= 200 and status < 300
end

-- resource management
local channel_resources = {}

-- route framework
local R = {
	tasks = {},
	channels = {},
	resources = channel_resources,	-- for n4c architecture, removing in init_worker.lua

	-- the options:
	--	host 		: current nginx host ip, default is inherited from ngx_cc.cluster.master.host, or '127.0.0.1'
	--	port 		: current nginx listen port, invalid with <manual> initializer only, and deault is '80'
	--	dict 		: shared dictionary name in nginx.conf, default is 'ngxccv2_dict' in R.cluster.dict for all channels
	--	initializer : manual/automatic, default is automatic
	new = function(self, channel, options)
		local function clone(src, dest)
			dest = dest or {};
			for name, value in pairs(src) do
				dest[name] = value
			end
			return dest
		end

		local R, options = self, options or {}
		local host = options.host or R.cluster.master.host or '127.0.0.1'
		local c_dict = options and options.dict or R.cluster.dict
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
		local key_registed_workers = 'ngx_cc.'..channel..'.registed.workers'
		local key_registed_clients = 'ngx_cc.'..channel..'.registed.clients'
		local invalid = { master = nil, super = nil }	-- continuous invalid for direction+addr in current channel
		instance.cc = function(url, opt)
			local opt = (type(opt) == 'string') and { direction = opt } or opt or R.optionAgain()
			if opt.method == nil then
				opt.method = ngx.HTTP_GET
			elseif type(opt.method) == 'string' then
				opt.method = ngx['HTTP_'..opt.method]
			end

			if not opt.direction then
				opt.direction =  cluster.worker_initiated and 'master' or 'skip'
			elseif ((opt.direction == 'super' and instance.isRoot()) or
					(opt.direction == 'master' and not cluster.worker_initiated)) then
				opt.direction = 'skip'
			end

			if opt.always_forward_body then
				if opt.method == ngx.HTTP_POST then
					ngx.req.read_body()
				else
					opt.always_forward_body = false
				end
			end

			local addr = string.match(url, '^[^/]*//[^/]+')
			local uri = string.sub(url, string.len(addr or '')+1)
			local uri2 = uri:gsub(c_patt, c_path, 1):gsub(c_patt2, c_path2, 1);
			local r_status, r_resps, errRequests = true, {}, {}

			if opt.direction == 'master' then
				local ctx2 = { cc_headers = nil } -- the <nil> will reset to default 'ON'
				local opt2 = setmetatable({
					vars = {
						cc_host = cluster.router.host,
						cc_port = cluster.router.port,
					},
					ctx = not opt.ctx and ctx2 or (not opt.ctx.cc_headers and setmetatable(ctx2, { __index = opt.ctx })) or nil,
				}, {__index=opt});

				local resp = ngx.location.capture(uri2, opt2);
				r_status = HTTP_SUCCESS(resp.status)
				r_resps = { resp }

				if r_status then
					if not invalid.master then invalid.master = nil end
				else
					invalid.master = invalid.master and (invalid.master + 1) or 1
					if invalid.master > 15 then -- continuous invalid
						-- TODO: the master is fail/invalid. kick all ???
						ngx_log(ngx.ALERT, 'direction master is invalid at port ' .. cluster.router.port)
					end
				end

				-- local fmt = 'Cast from port %s to master, ' .. (r_status and 'done.' or 'error with status %d.')
				-- ngx_log(ngx.INFO, string.format(fmt, cluster.worker.port, resp.status))
			elseif opt.direction == 'super' then
				local ctx2 = { cc_headers = 'OFF' }
				local opt2 = setmetatable({
					vars = {
						cc_host = cluster.super.host,
						cc_port = cluster.super.port,
					},
					ctx = not opt.ctx and ctx2 or (not opt.ctx.cc_headers and setmetatable(ctx2, { __index = opt.ctx })) or nil,
				}, {__index=opt})

				local resp = ngx.location.capture(uri2, opt2)
				r_status = HTTP_SUCCESS(resp.status)
				r_resps = { resp }

				if r_status then
					if not invalid.super then invalid.super = nil end
				else
					invalid.super = invalid.super and (invalid.super + 1) or 1
					if invalid.super > 15 then -- continuous invalid
						ngx_log(ngx.ALERT, 'direction super is invalid at ' .. cluster.super.host .. ':' .. cluster.super.port)
					end
				end

				-- local fmt = 'Cast from port %s to super, ' .. (r_status and 'done.' or 'error with status %d.')
				-- ngx_log(ngx.INFO, string.format(fmt, cluster.worker.port, resp.status))
			elseif opt.direction == 'workers' then
				local reqs, ports, registed_ports = {}, {}, channel_resources[key_registed_workers] or {}
				local ctx2, opt2 = { cc_headers = nil } -- the <nil> will reset to default 'ON'
				for _, port in ipairs(registed_ports) do
					opt2 = setmetatable({
						vars = {
							cc_host = cluster.master.host,
							cc_port = port,
						},
						ctx = not opt.ctx and ctx2 or (not opt.ctx.cc_headers and setmetatable(ctx2, { __index = opt.ctx })) or nil,
					}, {__index=opt});
					table.insert(reqs, { uri2, opt2 });
					table.insert(ports, port);
				end

				if #ports > 0 then
					local resps, errPorts = { ngx.location.capture_multi(reqs) }, {}
					for i, resp, key in ipairs(resps) do
						resp.port = ports[i]
						key = cluster.master.host .. ':' .. resp.port
						if not HTTP_SUCCESS(resp.status) then
							table.insert(errPorts, ports[i])
							table.insert(errRequests, {instance.cc, '/_/invoke',
								{ direction='master', args={invalidWorker=ports[i], t=invalid[key]} }})
							invalid[key] = invalid[key] and (invalid[key] + 1) or 1
						else
							if not invalid[key] then invalid[key] = nil end
						end
					end
					r_status = #errPorts == 0
					r_resps = resps

					if not r_status then instance.all(errRequests) end
					-- local fmt = 'Cast from port %s to workers: %d/%d, ' .. (r_status and 'done.' or 'and no passed ports: %s.')
					-- ngx_log(ngx.INFO, string.format(fmt, cluster.worker.port, #reqs, #resps, table.concat(errPorts, ',')))
				end
			elseif opt.direction == 'clients' then
				local reqs, clients, registed_clients = {}, {}, channel_resources[key_registed_clients] or {}
				local ctx2, opt2 = { cc_headers = nil } -- the <nil> will reset to default 'ON'
				for _, client in ipairs(registed_clients) do
					local client, port = unpack(client)
					opt2 = setmetatable({
						vars = {
							cc_host = client,
							cc_port = string.sub(port or '', 2),
						},
						ctx = not opt.ctx and ctx2 or (not opt.ctx.cc_headers and setmetatable(ctx2, { __index = opt.ctx })) or nil,
					}, {__index=opt})
					table.insert(reqs, { uri2, opt2 });
					table.insert(clients, client..port);
				end

				if #clients > 0 then
					local resps, errClients, errRequests = { ngx.location.capture_multi(reqs) }, {}, {}
					for i, resp, key in ipairs(resps) do
						resp.client = clients[i]
						key = resp.client
						if not HTTP_SUCCESS(resp.status) then
							table.insert(errClients, clients[i])
							table.insert(errRequests, {instance.cc, '/_/invoke',
								{ direction='master', args={invalidClient=clients[i], t=invalid[key]} }})
							invalid[key] = invalid[key] and (invalid[key] + 1) or 1
						else
							if not invalid[key] then invalid[key] = nil end
						end
					end
					r_status = #errClients == 0
					r_resps = resps

					if not r_status then instance.all(errRequests) end
					-- local fmt = 'Cast from port %s to clients: %d/%d, ' .. (r_status and 'done.' or 'and no passed clients: %s.')
					-- ngx_log(ngx.INFO, string.format(fmt, cluster.worker.port, #reqs, #resps, table.concat(errClients, ',')))
				end
			end

			return r_status, r_resps
		end

		-- cast to self, support '^/_/' replacer in route.self()
		instance.self = function(url, opt)
			return R.self(url:gsub(c_patt, c_path, 1), opt)
		end

		-- cast to all workers (with current worker)
		instance.cast = function(url, opt)
			return instance.cc(url, R.optionAgain('workers', opt))
		end

		-- check current node is root
		instance.isRoot = function()
			local master, su = cluster.master, cluster.super
			return not su or (su.host == master.host and su.port == master.port)
		end

		-- check current worker is master, else false will cast to 'master' with full invoke data
		instance.isInvokeAtMaster = function()
			if cluster.worker.port ~= cluster.router.port then
				return false, instance.cc('/_/_'..ngx.var.uri);
			else
				return true
			end
		end

		-- check current is per-worker, else false will cast to 'workers' with full invoke data
		instance.isInvokeAtPer = function()
			if cluster.worker.port ~= ngx.var.server_port then
				return false, instance.cc('/_/_'..ngx.var.uri, instance.optionAgain('workers'));
			else
				return true
			end
		end

		-- reset super
		instance.transfer = function(super, ...)
			local host, port = string.match(super, '([^/:]*):?(%d*)$')
			cluster.super.host, cluster.super.port = host, port or ({...})[1] or '80'
		end

		-- channel initiatation
		local kernal = ngx_cc_core.kernal_initializer
		local initializer = kernal[options.initializer or 'automatic'] or kernal.automatic
		initializer(instance, channel, options)

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
		always_forward_body = true,
		method 	= ngx.req.get_method(),
		args 	= ngx.req.get_uri_args(),
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

-- cast to self, it's warp of ngx.location.capture() only
--	1) for ngx_cc.self(), cant use '^/_/' replacer in url
function R.self(url, opt)
	local resp = ngx.location.capture(url, opt);
	-- ngx_log(ngx.INFO, 'Cast to self: ' .. (r_status and 'done.' or 'and no passed.'))
	return HTTP_SUCCESS(resp.status), { resp }
end

-- cast to remote, RPC
function R.remote(url, opt)
	local addr = string.match(url, '^[^/]*//[^/]+')
	local uri = string.sub(url, string.len(addr or '')+1)
	assert(addr, 'need full remote url')
	local uri2, host, port = '/_/cast' .. uri, string.match(addr, '^[^/]*//([^:]+):?(.*)')
	local ctx, ctx2 = opt and opt.ctx or nil, { cc_headers = 'OFF' }
	local resp = ngx.location.capture(uri2, setmetatable({
		vars = {
			cc_host = host,
			cc_port = port,
		},
		ctx = not ctx and ctx2 or (not ctx.cc_headers and setmetatable(ctx2, { __index = ctx })) or nil,
	}, {__index=opt}));
	-- local fmt = 'Cast from port %s to remote: %s, ' .. (r_status and 'done.' or 'error with status %d.')
	-- ngx_log(ngx.INFO, string.format(fmt, cluster.worker.port, addr, resp.status))
	return HTTP_SUCCESS(resp.status), { resp }
end

-- simple say() all responses body for R.cc() result
function R.say(r_status, r_resps)
	for _, resp in ipairs(r_resps) do
		if resp then -- false value, or a resp object
			if (HTTP_SUCCESS(resp.status) and (type(resp.body) == 'string') and
				(string.len(resp.body) > 0)) then
				ngx.say(resp.body)
			end
			if #resp > 0 then R.say(r_status, resp) end -- deep
		end
	end
end

-- capture all requests and return, ngx.thread based
function R.all(requests, comment)  -- comment is log only

	local function future(threads)
		return setmetatable({}, {
			__index = function(t, key)  -- call once only
				for i, co in ipairs(threads) do
					local FAIL, success, captured, resps = false, ngx.thread.wait(co)
					rawset(t, i, (success and captured) and (#resps>1 and resps or resps[1]) or FAIL)
				end
				getmetatable(t).__index = nil
				return rawget(t, key)
			end
		})
	end

	local threads = {}
	for _, request in ipairs(requests) do
		table.insert(threads, ngx.thread.spawn(request[1], unpack(request, 2)))
	end

	-- try wait all thread once, and return all status
	local results, ok = future(threads), 0
	for i = 1, #threads do
		if results[i] then ok = ok + 1 end
	end

	-- local fmt = (comment or 'all requests') .. ' done, %d/%d success.'
	-- ngx_log(ngx.INFO, string.format(fmt, ok, #threads))
	return ok>0, results
end

-- map <keys> to named index table
local function maped(keys, map)
	local map = map or {}
	for _, key in ipairs(keys) do map[key] = true end
	return map
end

-- see: https://coronalabs.com/blog/2013/04/16/lua-string-magic/
local function split(self, inSplitPattern, outResults)
	local theStart, thePatten, result = 1, inSplitPattern or ',', outResults or {}
	local theSplitStart, theSplitEnd = string.find(self, thePatten, theStart)
	while theSplitStart do
		table.insert(result, string.sub(self, theStart, theSplitStart-1))
		theStart = theSplitEnd + 1
		theSplitStart, theSplitEnd = string.find(self, thePatten, theStart)
	end
	table.insert(result, string.sub(self, theStart ))
	return result
end

-- check empty table
local function isEmpty(t)
	return next(t) == nil
end

-- transfer server at root/super
function R.transfer(super, channels, clients)
	local channels = channels == '*' and R.channels or split(channels)
	local clients = clients == '*' and {} or maped(split(clients))
	local forAll, requests, opt = isEmpty(clients), {}, { args={transferServer=super} }
	for channel in pairs(channels) do
		local saved, instance, key_registed_clients = {}, R.channels[channel], 'ngx_cc.'..channel..'.registed.clients'
		local registed_clients = channel_resources[key_registed_clients] or {}
		for client, port in ipairs(registed_clients) do
			if forAll or clients[client] then
				table.insert(requests, {instance.remote, 'http://'..client..port..'/'..channel..'/invoke', opt})
			else
				table.insert(saved, client..port)
			end
		end
		-- saving
		instance.shared:set(key_registed_clients, table.concat(saved, ','))
	end
	-- remote call these removed clients
	R.all(requests)
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
		ngx.exit(ngx.HTTP_OK)
	end
	-- ngx.log(ngx.INFO, table.concat({'', channel, ngx.var.cc_host, ngx.var.cc_port, ''}, '||'))
end

-- reosure getter for native ngx_cc, direct read shared dictionary
-- 	*) saving iterator of worker/clients direction, uses unpack(iterator) to got values by caller
local registed_keys = {}
setmetatable(channel_resources, {__index = function(t, key)
	local channel, direction = unpack(registed_keys[key] or {false})
	if channel == false then
		local ngx_cc_registed_key = '^ngx_cc%.([^%.]+)%.registed%.([^%.]+)$'
		channel, direction = string.match(key, ngx_cc_registed_key)
		registed_keys[key] = {channel, direction}
	end

	local instance = channel and direction and R.channels[channel]
	if instance and (direction == 'workers' or direction == 'clients') then
		local registed, newValue = instance.shared:get(key), {}
		if registed then
			if direction == 'workers' then
				for port in string.gmatch(registed, '(%d+)[^,]*,?') do table.insert(newValue, port) end
			elseif direction == 'clients' then
				for host, port in string.gmatch(registed, '([^:,]+)([^,]*),?') do table.insert(newValue, {host, port}) end
			end
		end
		return newValue
	end
end})

-- base struct for multi-workers sub-system
R.cluster = {
	super =  { host='127.0.0.1', port='80' },	-- cc:super
	master = { host='127.0.0.1' },				-- cc:workers, use <master.host> and communication in workes only
	dict = 'ngxcc_dict',						-- default cluster/global dictionry name
	report_clients = false,						-- false only, non implement now
}
-- current worker
R.cluster.worker = {
	host = R.cluster.master.host,
	port = assert(ngx.worker.port and tostring(ngx.worker.port()), 'require per_worker with get_per_port patch'),
}
-- cc:master, and will reset <port> in ngx_cc_core.lua
R.cluster.router = { host=R.cluster.master.host }

return R
