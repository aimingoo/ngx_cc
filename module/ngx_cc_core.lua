-----------------------------------------------------------------------------
-- NGX_CC v1.0.0
-- Author: aimingoo@wandoujia.com
-- Copyright (c) 2015.02
-- Descition:　a framework of Nginx Communication Cluster. reliable
--	dispatch/translation　messages in nginx nodes or processes.
--
-- core method or actions
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

-- register current worker on master
--	/channel_name/invoke?registerWorker
local function registerWorker(route, channel, arg)
	local shared, key = route.shared, 'ngx_cc.registed.workers'
	local registedWorkers = shared:get(key)

	local workers = { arg.registerWorker or 80 }
	if not registedWorkers then
		shared:add(key, workers[1])
	else -- dedup and save
		for port in string.gmatch(registedWorkers, "(%d+),?") do
			if port ~= workers[1] then
				table.insert(workers, port)
			end
		end
		shared:set(key, table.concat(workers, ','))
	end
end

-- report client workport to super
--	/channel_name/invoke?reportClient=xxxx
local function reportClient(route, channel, arg)
	if arg.reportClient ~= '' and _isInvokeAtMasterAA(route, arg) then
		local shared, key = route.shared, 'ngx_cc.registed.clients.'.. ngx.var.remote_addr
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
		local shared, key = route.shared, 'ngx_cc.registed.clients'
		local masterPort, registedClients = arg.reportHubPort, shared:get(key)
		if masterPort ~= '' then
			masterPort = (masterPort == '80' and '' or ':'..masterPort)
		end

		local clients = { ngx.var.remote_addr .. masterPort }
		if not registedClients then
			shared:add(key, clients[1])
		else -- dedup and save
			for client, port in string.gmatch(registedClients, '([^:,]+)([^,]*),?') do
				if client ~= clients[1] then
					table.insert(clients, client .. port)
				end
			end
			shared:set(key, table.concat(clients, ','))
		end
	end
end

-- manual initializer, need per_worker with get_per_port patcher
local manual_initializer = function(route, cluster, channel, options)
	cluster.master.port = options.port or '80'
	-- cluster.worker.port = assert(ngx.worker.port and ngx.worker.port(), 'require per_worker with get_per_port patcher')
	cluster.worker.port = ''

	-- try register RouterPort
	local shared, key = route.shared, 'ngx_cc.RouterPort'
	local port = assert(shared:get(key), 'cant find RouterPort from '..c_dict)
	cluster.router.port = port
	cluster.worker_initiated = port ~= nil
end

-- (default) automatic initializer, need bash and lsof
local automatic_initializer = function(route, cluster, channel, options)
	-- send request to self, dependencies:
	--	/bin/bash		## support build-in: read, exec, and Bash socket programming.
	--	/usr/sbin/lsof
	-- see also:
	--	http://www.linuxjournal.com/content/more-using-bashs-built-devtcp-file-tcpip
	--	http://thesmithfam.org/blog/2006/05/23/bash-socket-programming-with-devtcp-2/
	function requestSelf(action)
		local cmd = '/usr/sbin/lsof -sTCP:LISTEN -Pani -Fn -p ' .. ngx.worker.pid() .. ' | /bin/bash -c \'' ..
			'NC="&lsof=";LINES="";PORT="80";while read -r LINE; do LINES="$LINES$NC$LINE"; NC="%20"; PORT2=${LINE##n*:}; if ((PORT2>PORT)); then PORT=$PORT2; fi; done;' ..
			'exec 4<>/dev/tcp/' .. cluster.master.host .. '/$PORT; ' ..
			'echo -e "GET /' .. channel .. '/invoke?' .. action .. '$LINES HTTP/1.0\\n\\n" >&4; ' ..
			'exec 4>&-\' &'
		os.execute(cmd)
	end

	-- /channel_name/invoke?setWorker&lsof=p14739%20n*:80%20n*:8080
	function setWorker(route, channel, arg)
		-- init worker infomation
		-- worker.host = ngx.var.server_addr,
		local worker, master = cluster.worker, cluster.master
		worker.pid, worker.port = ngx.var.pid, ngx.var.server_port

		-- try register me as RouterPort
		local shared, key = route.shared, 'ngx_cc.RouterPort'
		local port = shared:get(key)
		if port then
			cluster.router.port = port
		elseif shared:add(key, worker.port) then
			cluster.router.port = worker.port
		else
			cluster.router.port = shared:get(key)
		end

		-- master setting
		local installed, process = pcall(function(mod) return require(mod) end, 'process') -- try load 'process' module
		if not installed then
		 	process = require('module.procfs_process') -- load 'procfs_process' again
		end
		master.pid = process:getppid(worker.pid)
		for port in string.gmatch(arg.lsof or '', "n[^:]+:(%d+) ?") do
			if port ~= worker.port then
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

		-- current worker is initialized, and register me on master
		--	PORT/channel_name/invoke?registerWorker=xxx
		cluster.worker_initiated = true
		route.cc('/_/invoke', { direction='master', args={registerWorker=worker.port} })

		-- report me as client
		--	SUPER:PORT/channel_name/invoke?reportClient=xxx
		if cluster.report_clients then
			route.cc('/_/invoke', { direction='super', args={reportClient=worker.port} })
		end

		-- report hubPort, once of router.
		--	SUPER:PORT/channel_name/invoke?reportHubPort=xxx
		if worker.port == cluster.router.port then
			route.cc('/_/invoke', { direction='super', args={reportHubPort=master.port} })
		end

		-- !!! initialized !!!
		ngx.log(ngx.ALERT, worker.pid .. ' listen at port ' .. worker.port .. ', ',
			'router.port: ' .. cluster.router.port .. ', ',
			'and master pid/port: ' .. master.pid .. '/' .. master.port .. '.')
	end

	-- when work initiating, the requestSelf() will send a system process as daemon
	route.invoke.setWorker = setWorker
	requestSelf('setWorker')
end

-- core
return {
	kernal_actions = {
		reportClient = reportClient,
		reportHubPort = reportHubPort,
		registerWorker = registerWorker
	},
	kernal_initializer = {
		manual = manual_initializer,
		automatic = automatic_initializer
	}
}