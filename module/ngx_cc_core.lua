-----------------------------------------------------------------------------
-- NGX_CC v2.0.0
-- Author: aimingoo@wandoujia.com
-- Copyright (c) 2015.02-2015.08
-- Descition:　a framework of Nginx Communication Cluster. reliable
--	dispatch/translation　messages in nginx nodes or processes.
--
-- core method or actions, need module/procfs_process.lua module 
-----------------------------------------------------------------------------

-- cast to master with real remote_client address
local function _isInvokeAtMasterAA(route, arg)
	if route.cluster.worker.port ~= route.cluster.router.port then
		return false, route.cc(ngx.var.uri, route.optionAgain({
			direction = 'master',
			args = { clientAddr = ngx.var.remote_addr } -- Attach_Address
		}));
	else
		if arg.clientAddr then
			if ngx.var._faked_by_cc_ then
				ngx.var.remote_addr = arg.clientAddr
			else
				ngx.var = setmetatable({remote_addr = arg.clientAddr, _faked_by_cc_ = true }, { __index = ngx.var }) -- rewrite
			end
			arg.clientAddr = nil
		end
		return true
	end
end

local function success_initialized(route, channel)
	local cluster = route.cluster
	local worker, master, router = cluster.worker, cluster.master, cluster.router
	ngx.log(ngx.ALERT, worker.pid .. ' listen at port ' .. worker.port .. ', [',
		channel .. '] router.port: ' .. router.port .. ', ',
		'and master pid/port: ' .. master.pid .. '/' .. master.port .. '.')
end

-- register current worker on master
--	/channel_name/invoke?registerWorker
local function registerWorker(route, channel, arg)
	local shared, cluster = route.shared, route.cluster
	local key_registed_workers = 'ngx_cc.'..channel..'.registed.workers'
	local registedWorkers = shared:get(key_registed_workers)

	local worker_port = arg.registerWorker or '80'
	local workers = { worker_port .. '/' .. arg.pid }
	if not registedWorkers then
		shared:add(key_registed_workers, workers[1])
	else -- dedup and save, check valid for per worker process
		local ps, master_pid = require('lib.posix'), tonumber(cluster.master.pid)
		local function is_valid_workerprocess(pid)
			return ps.pgid(tonumber(pid)) == master_pid  -- pgid is '-1' or pid of master process
		end
		for worker in string.gmatch(registedWorkers, "([^,]+),?") do
			if (worker ~= workers[1]) then
				local pid = string.match(worker, '%d+$')
				if is_valid_workerprocess(pid) then
					table.insert(workers, worker)
				end
			end
		end
		shared:set(key_registed_workers, table.concat(workers, ','))
	end
end

-- report client workport to super
--	/channel_name/invoke?reportClient=xxxx
local function reportClient(route, channel, arg)
	if arg.reportClient ~= '' and _isInvokeAtMasterAA(route, arg) then
		local key_registed_clients = 'ngx_cc.'..channel..'.registed.clients'
		local shared, key = route.shared, key_registed_clients .. '.' .. ngx.var.remote_addr
		local clientPorts = shared:get(key)

		local ports = { arg.reportClient }
		if not clientPorts then
			shared:add(key, ports[1])
		else -- dedup and save
			for port in string.gmatch(clientPorts, "(%d+),?") do
				if port ~= ports[1] then
					table.insert(ports, port)
				end
			end
			shared:set(key, table.concat(ports, ','))
		end
	end
end

-- report client hubport to super
--	/channel_name/invoke?reportHubPort=xxx
local function reportHubPort(route, channel, arg)
	if _isInvokeAtMasterAA(route, arg) then
		local shared = route.shared
		local key_registed_clients = 'ngx_cc.'..channel..'.registed.clients'
		local masterHost, masterPort, registedClients = ngx.var.remote_addr, arg.reportHubPort, shared:get(key_registed_clients)
		if masterPort ~= '' then
			masterPort = (masterPort == '80' and '' or ':'..masterPort)
		end

		local clients = { masterHost .. masterPort }
		if not registedClients then
			shared:add(key_registed_clients, clients[1])
		else -- dedup and save
			for client, port in string.gmatch(registedClients, '([^:,]+)([^,]*),?') do
				if client ~= masterHost then
					table.insert(clients, client .. port)
				end
			end
			shared:set(key_registed_clients, table.concat(clients, ','))
		end
	end
end

-- manual initializer, need per_worker with get_per_port patcher
local manual_initializer = function(route, channel, options)
	local cluster = route.cluster
	cluster.master.port = options.port or '80'
	cluster.worker.port = tostring(ngx.worker.port())

	-- try register RouterPort
	local shared, key = route.shared, 'ngx_cc.'..channel..'.RouterPort'
	local port = assert(shared:get(key), 'cant find RouterPort from dictionary.')
	cluster.router.port, cluster.router.pid = string.match(port, '^(%d+)/(%d+)')
	cluster.worker_initiated = port ~= nil
	success_initialized(route, channel)
end

-- (default) automatic initializer, need bash and lsof
local automatic_initializer = function(route, channel, options)
	-- send request to self, dependencies:
	--	/bin/bash		## support build-in: read, exec, and Bash socket programming.
	--	/usr/sbin/lsof
	-- see also:
	--	http://www.linuxjournal.com/content/more-using-bashs-built-devtcp-file-tcpip
	--	http://thesmithfam.org/blog/2006/05/23/bash-socket-programming-with-devtcp-2/
	local function requestSelf_BASH(action)
		local cmd = '/usr/sbin/lsof -sTCP:LISTEN -Pani -Fn -p ' .. ngx.worker.pid() .. ' | /bin/bash -c \'' ..
			'NC="&lsof=";LINES="";PORT="80";while read -r LINE; do LINES="$LINES$NC$LINE"; NC="%20";'..
			'  PORT2=${LINE##n*:}; if ((PORT2==433)); then continue; fi; if ((PORT2>PORT)); then PORT=$PORT2; fi; done;' ..
			'exec 4<>/dev/tcp/' .. route.cluster.master.host .. '/$PORT; ' ..
			'echo -e "GET /' .. channel .. '/invoke?' .. action .. '$LINES HTTP/1.0\\n\\n" >&4; ' ..
			'exec 4>&-\' &'
		os.execute(cmd)
	end

	-- fake a lsof result, runtime only
	--	sample: setWorker&lsof=p14739%20n*:80%20n*:8080
	local function LSOF_LINES()
		return table.concat({
			 'p'..route.cluster.worker.pid,
			'*:'..route.cluster.master.port,
			'*:'..route.cluster.worker.port
		}, ' ')
	end

	-- fake a requestSelf_BASH() with ngx_cc.remote(), in runtime
	local function requestSelf_CC(action)
		route.remote('http://'..route.cluster.master.host ..
			':' .. route.cluster.worker.port ..
			'/' .. channel .. '/invoke', { arg = {[action] = true, lsof = LSOF_LINES()} })
	end

	-- fake a requestSelf_BASH(), and direct call route.invoke.setWorker
	local function requestSelf_DIRECT(action)
		pcall(route.invoke.setWorker, rotue, channel, { lsof = LSOF_LINES() })
	end

	-- /channel_name/invoke?setWorker&lsof=p14739%20n*:80%20n*:8080
	local function setWorker(route, channel, arg)
		-- init worker infomation
		--	*) you can set worker.port by ngx.var.server_port without 'get_per_port' patch
		local cluster = route.cluster
		local worker, master = cluster.worker, cluster.master
		worker.pid, worker.port = ngx.var.pid, tostring(ngx.worker.port())

		-- try register me as RouterPort
		local shared, key = route.shared, 'ngx_cc.'..channel..'.RouterPort'
		local port = shared:get(key)
		if port then
			cluster.router.port, cluster.router.pid = string.match(port, '^(%d+)/(%d+)')
		elseif shared:add(key, (worker.port .. '/' .. worker.pid)) then
			cluster.router.port, cluster.router.pid = worker.port, worker.pid
		else
			port = assert(shared:get(key), 'cant access router port from dictionary') -- again
			cluster.router.port, cluster.router.pid = string.match(port, '^(%d+)/(%d+)')
		end

		-- master setting
		local ps = require('lib.posix')
		local function is_valid_workerprocess(pid)
			return ps.pgid(tonumber(pid)) == tonumber(master.pid)  -- pgid is '-1' or pid of master process
		end
		master.pid = tostring(ps.ppid(tonumber(worker.pid)))
		for port in string.gmatch(arg.lsof or '', "n[^:]+:(%d+) ?") do
			if (port ~= '433') and (port ~= worker.port) then
				master.port = port
				break
			end
		end

		-- super setting
		if cluster.super then
			local su = cluster.super
			if not su.host or (su.host == '') then
				su.host = master.host
			end
			if not su.port or (su.port == '') then
				su.port = master.port
			end
		end

		-- current worker is initialized
		--	PORT/channel_name/invoke?registerWorker=xxx
		cluster.worker_initiated = true
		if cluster.router.pid ~= worker.pid then -- router port&pid check, promise 'master' direction valid
			if ((cluster.router.port == worker.port) or -- new worker process reopen at old port, old pid invalid
				(not is_valid_workerprocess(cluster.router.pid))) then -- router worker process crush or exit
				cluster.router.port, cluster.router.pid = worker.port, worker.pid -- set me only
				-- shared:set(key, (worker.port .. '/' .. worker.pid)) -- register me as RouterPort delay, @see n4cDistrbutionTaskNode.lua module in ngx_4c
			end
		end
		route.cc('/_/invoke', { direction='master', args={registerWorker=worker.port, pid=worker.pid} })

		-- report me as client
		--	SUPER:PORT/channel_name/invoke?reportClient=xxx
		if cluster.report_clients then
			route.cc('/_/invoke', { direction='super', args={reportClient=worker.port} })
		end

		-- report hubPort, once for router, and will remove old hubPort by per-channel in super
		--	SUPER:PORT/channel_name/invoke?reportHubPort=xxx
		if worker.port == cluster.router.port then
			route.cc('/_/invoke', { direction='super', args={reportHubPort=master.port} })
		end

		success_initialized(route, channel)
	end

	-- when work initiating, the requestSelf() will send a system process as daemon
	local parse = ngx.get_phase()
	assert(parse ~= 'init', 'initiating ngx_cc channel [' .. channel .. '] in init_by_lua*')
	local requestSelf = (parse == 'init_worker') and requestSelf_BASH or requestSelf_DIRECT
	route.invoke.setWorker = setWorker
	requestSelf('setWorker')
end

-- core
return {
	kernal_actions = {
		reportClient = reportClient,
		reportHubPort = reportHubPort,
		registerWorker = registerWorker,
	},
	kernal_initializer = {
		manual = manual_initializer,
		automatic = automatic_initializer,
	}
}