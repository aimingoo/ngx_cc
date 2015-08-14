-- -----------------------------------------------------------------------------
-- This is a sample init_worker.lua of ngx_cc
--	1) please read sample nginx.conf first
--	2) multi channels is optional, all functions can work in singel channel
-- 	3) tasks management(and heartbeat module) is optional
-- 	4) need install lua-process module on macosx(procfs is unsupported)
-- 		- https://github.com/mah0x211/lua-process
-- -----------------------------------------------------------------------------

-- load ngx_cc framework
ngx_cc = require('ngx_cc')

-- case one: base test
route = ngx_cc:new('test')	-- work at 'test' channel
require('module.invoke').apply(route)

-- case two: full test, more module/feature to route2.invoke
--	 1) with sample invokes
--	 2) with heartbeat (include tasks management)
--	 3) with cluster invalid checker
route2 = ngx_cc:new('kada')	-- work at 'kada' channel
require('module.invoke').apply(route2)
require('module.heartbeat').apply(route2)
require('module.invalid').apply(route2)

-- custom route2.invoke
route2.invoke.showMe = function()
	ngx.say('Hi, Welcome to the ngx_cc cluster.')
end

ngx.log(ngx.ALERT, 'DONE. in init_worker.lua')