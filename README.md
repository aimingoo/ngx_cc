# ngx_cc
A framework of Nginx Communication Cluster. reliable distranslation messages in nginx nodes and processes.

The chinese intro document at here: [chinese wiki](https://github.com/aimingoo/ngx_cc/wiki/%E7%AE%80%E4%BB%8B).

The framework support:
> * communication between cluster nodes and worker processes, with directions: super/clients, master/workers
> * native ngx.location.capture* based, support coroutine sub-request
>  * without cosocket (not dependent)
> * multi channels and sub-channels supported
> * multi-root or cross-cluster communication supported
> * full support NGX_4C programming architecture
>	* http://github.com/aimingoo/ngx_4c

The contents of current document:
> * [environment](#environment)
> * [run testcase with ngx_cc](#run-testcase-with-ngx_cc)
> * [build cluster configures](#build-cluster-configures)
> * [programming](#programming-with-ngx_cc)
> * [APIs](#apis)
>  * [modules in the framework](#modules-in-the-framework)
>  * [locations in nginx.conf](#locations-in-nginxconf)
>  * [ngx_cc APIs](#ngx_cc-apis)
>  * [route APIs](#route-apis)
> * [History and update](#history)

## environment
Requirements:
* nginx + lua
* per-worker-listener patch, a update version included (original version from Roman Arutyunyan)

Optional:
* require ngx_tasks by heartbeat module, from:
 * http://github.com/aimingoo/ngx_tasks
* require Valider by invalid module, from:
 * http://github.com/aimingoo/Valider
* require JSON by simple/standard invoke module, from:
 * http://regex.info/blog/lua/json

all optional module saved to ngx_cc/lib/*, by default.
#### 1) install nginx+lua
OpenResty is recommend([here](http://openresty.org/))，or install nginx+lua, see:
> [http://wiki.nginx.org/HttpLuaModule#Installation](http://wiki.nginx.org/HttpLuaModule#Installation)

#### 2) install per-worker-listener patch
need install/apply these patchs before compile nginx+lua, see:
> /patchs/run.sh

please read the script, apply patchs and compile/rebuild nginx.

#### 3) test in the nginx environment
write a ngxin.conf, and put to home of current user:
```conf
##
## vi ~/nginx.conf
##
user  nobody;
worker_processes  4;

events {
    worker_connections  10240;
    accept_mutex off;  ## per-worker-listener patch required
}

http {
    server {
        listen     80;
        listen     8010 per_worker; ## per-worker-listener patch required
        server_name  localhost;

        location /test {
            content_by_lua '
                ngx.say("pid: " .. ngx.var.pid .. ", port: " .. ngx.var.server_port .. "\tOkay.")';
        }
    }
}
```
Ok. now start nginx and run testcase:
```bash
> sudo sbin/nginx -c ~/nginx.conf
> for port in 80 {8010..8013}; do curl "http://127.0.0.1:$port/test"; done
```
if success, output(pid changeable):
```
pid: 24017, port: 80    Okay.
pid: 24016, port: 8010  Okay.
pid: 24017, port: 8011  Okay.
pid: 24018, port: 8012  Okay.
pid: 24019, port: 8013  Okay.
```

## run testcase with ngx_cc
download ngx_cc:
```bash
> cd ~
> git clone https://github.com/aimingoo/ngx_cc

# or

> cd ~
> wget https://github.com/aimingoo/ngx_cc/archive/master.zip -O ngx_cc.zip
> unzip ngx_cc.zip -d ngx_cc/
> mv ngx_cc/ngx_cc-master/* ngx_cc/
> rm -rf ngx_cc/ngx_cc-master
```
run nginx with prefix parament:
```bash
> # cd home directory of nginx
> sudo ./sbin/nginx -c ~/ngx_cc/nginx.conf -p ~/ngx_cc
```
and test it:
> curl http://127.0.0.1/test/hub?getServiceStat
{"clients":[],"ports":"8012,8011,8010,8013","routePort":"8011","service":"127.0.0.1:80"}
> curl http://127.0.0.1/kada/hub?showMe
Hi, Welcome to the ngx_cc cluster!
```

## build cluster configures
This is base demo for a simple cluster.

1) clone demo configures and change it
```bash
# clone configures
> cp ~/work/ngx_cc/nginx.conf ~/work/ngx_cc/nginx.conf.1
> cp ~/work/ngx_cc/nginx.conf ~/work/ngx_cc/nginx.conf.2

# change next lines with '90' or '9091' and pid.1
> grep -Pne 'pid\t|listen\t' ~/work/ngx_cc/nginx.conf.1
13:pid      logs/nginx.pid.1;
36:             listen      90;
37:             listen      9010 per_worker;

# change next lines with '100' or '10091' and pid.2
> grep -Pne 'pid\t|listen\t' ~/work/ngx_cc/nginx.conf.2
13:pid      logs/nginx.pid.2;
36:             listen      100;
37:             listen      10010 per_worker;
```

2) run instances
```bash
> sudo ./nginx -c ~/work/ngx_cc/nginx.conf.1 -p ~/ngx_cc
> sudo ./nginx -c ~/work/ngx_cc/nginx.conf.2 -p ~/ngx_cc
```
OK, now, you will get a cluster with next topology: [here](https://github.com/aimingoo/ngx_cc/wiki/images/cluster_arch_4.png)

3) and, more changes(clients for a client)
```bash
# clone configures
> cp ~/work/ngx_cc/nginx.conf ~/work/ngx_cc/nginx.conf.11

# clone init_worker.lua
> cp ~/work/ngx_cc/init_worker.lua ~/work/ngx_cc/init_worker_11.lua

# change next lines with '1100' or '11010' and pid.11
> grep -Pne 'pid\t|listen\t' ~/work/ngx_cc/nginx.conf.11
13:pid      logs/nginx.pid.11;
36:             listen      1100;
37:             listen      11010 per_worker;

# change init_worker_11.lua, insert a line at after "require()"
> grep -A1 -Fe "require('ngx_cc')" ~/work/ngx_cc/init_worker_11.lua
ngx_cc = require('ngx_cc')
ngx_cc.cluster.super = { host='127.0.0.1', port='90' }
```
4) run instance with nginx.conf.11
```bash
> sudo ./nginx -c ~/work/ngx_cc/nginx.conf.11
```

5) print server list
```bash
> curl -s 'http://127.0.0.1/test/hub?getServiceStat' | python -m json.tool
{
    "clients": {
        "127.0.0.1:100": {
            "clients": [],
            "ports": "10011,10013,10010,10012",
            "routePort": "10012",
            "service": "127.0.0.1:100",
            "super": "127.0.0.1:80"
        },
        "127.0.0.1:90": {
            "clients": {
                "127.0.0.1:1100": {
                    "clients": [],
                    "ports": "11011,11012,11010,11013",
                    "routePort": "11013",
                    "service": "127.0.0.1:1100",
                    "super": "127.0.0.1:90"
                }
            },
            "ports": "9011,9013,9012,9010",
            "routePort": "9010",
            "service": "127.0.0.1:90",
            "super": "127.0.0.1:80"
        }
    },
    "ports": "8012,8010,8013,8011",
    "routePort": "8011",
    "service": "127.0.0.1:80"
}
```
check error.log in $(nginx)/logs to get more 'ALERT' information about initialization processes.
## programming with ngx_cc
#### 1) insert locations into your nginx.conf
you need change your nginx.conf base demo configures, the demo in $(ngx_cc)/nginx.conf.

and, insert three locations into your nginx.conf:
```conf
http {
	...

	server {
		...

		# caster, internal only
		location ~ ^/([^/]+)/cast {
			internal;
			set_by_lua $cc_host 'return ngx.var.cc_host';
			set_by_lua $cc_port 'local p = ngx.var.cc_port or ""; return (p=="" or p=="80") and "" or ":"..p;';
			rewrite ^/([^/]+)/cast/(.*)$ /$2 break;	# if no match, will continue next-rewrite, skip current <break> opt
			rewrite ^/([^/]+)/cast([^/]*)$ /$1/invoke$2 break;
			proxy_pass http://$cc_host$cc_port;
			proxy_read_timeout		2s;
			proxy_send_timeout		2s;
			proxy_connect_timeout	2s;
		}

		# invoke at worker listen port
		location ~ ^/([^/]+)/invoke {
			content_by_lua 'ngx_cc.invokes(ngx.var[1])';
		}

		# hub at main listen port(80), will redirect to route listen port
		location ~ ^/([^/]+)/hub {
			content_by_lua 'ngx_cc.invokes(ngx.var[1], true)';
		}
```

#### 2) add shared dictionary in your nginx.conf
```conf
http {
	...

	server {
		...

		lua_shared_dict ngxcc_dict 10M;
```

#### 3) initialization ngx_cc in init_worker.lua
configures of &lt;init_worker_by_lua_file&gt; in your nginx.conf:
```conf
http {
	...
	init_worker_by_lua_file '<your_projet_directory>/init_worker.lua';
```
and coding in init_worker.lua:
```lua
-- get ngx_cc instance
ngx_cc = require('ngx_cc')

-- get route instance for 'test' channel
route = ngx_cc:new('test')	-- work with 'test' channel

-- load invokes of 'test' channel
require('module.invoke').apply(route)  -- it's default module
require('module.heartbeat').apply(route) -- it's heartbeat module
require('module.YOURMODULE').apply(route) -- your modules
```
#### 4) write invokes in modules/*
write your invokes and put into $(ngx_cc)/modules/&lt;YOURMODULE&gt;.lua:
```lua
-- a demo invoke module
local function apply(invoke)
	invoke.XXXX = function(route, channel, arg)
		...
	end
	...
end

-- return invokes helper object
return {
	apply = function(route)
		return apply(route.invoke)
	end
}
```

#### 5) test your invokes
```bash
# run nginx with your nginx.conf, and call the test:
> curl 'http://127.0.0.1/test/invoke?XXXX
```
## APIs

There are published APIs of ngx_cc. The &lt;ngx_cc&gt; and &lt;route &gt; APIs for these intances/variants:
```lua
--
-- (in init_workers.lua)
--

-- get ngx_cc instance
ngx_cc = require('ngx_cc')

-- get route instance for 'test' channel
route = ngx_cc:new('test')	-- work with 'test' channel
```
### modules in the framework
```
> cd ~/ngx_cc/
> ls
ngx_cc.lua          -- main module
init_worker.lua     -- (demo init_worker.lua)
nginx.conf          -- (demo nginx.conf)

> cd module/
> ls
ngx_cc_core.lua     -- core module, load by ngx_cc.lua
heartbeat.lua       -- (heartbeat module, optional)
invoke.lua          -- (getServiceStat action, optional)
invalid.lua         -- (cluster invalid check, optional)

> cd ../lib/
> ls
JSON.lua            -- JSON format output, dependency by getServiceStat action.
ngx_tasks.lua       -- tasks management, dependency by ngx_cc.tasks interface, a example in module/heartbeat.lua
Valider.lua         -- invalid rate check, dependency by module/invalid.lua
posix.lua			-- a minimum posix system module

> cd ../patch
> ls
per-worker.patch      -- 'per_worker' directive in nginx.conf
ngx-worker-port.patch -- 'ngx.worker.port()' api in ngx_lua
run.sh                -- a demo launch
```

### locations in nginx.conf
these locations in nginx.conf:
```conf
		location ~ ^/([^/]+)/cast
		location ~ ^/([^/]+)/invoke
		location ~ ^/([^/]+)/hub
```
The regexp:
> ^/([^/]+)

will match channel_name of your request/api accesses. ex:
```bash
> curl 'http://127.0.0.1/test/invoke?XXXX
```
OR
```lua
-- lua code
route.cc('/test/invoke?XXXX', { direction = 'workers' })
```
for these cases, the channel_name is 'test'.

##### 1) location: /channel_name/cast
it's internal sub-request of ngx_cc. don't access it in your program. if you want boardcast messages, need call route.cast() from your code.
##### 2) location: /channel_name/invoke
it's main sub-request, access with route.cc() is commented. and you can seed http request from client(or anywhere):
```bash
> curl 'http://127.0.0.1/test/invoke?XXXX 
```
the 'XXXX' is &lt;action_name&gt; invoked at &lt;channel_name&gt;.

'/channel_name/invoke' will launch single worker process to answer request, it's unicast.
##### 3) location: /channel_name/hub
it's warp of '/channel_name/invoke' location.

the '/channel_name/hub' will launch 'router process' to answer request. the router is unique elected process by all workers.
### ngx_cc APIs
```
# internal
ngx_cc.tasks         : default tasks, drive by tasks management module/plugins, see module/heartbeat.lua or ngx_tasks project.
ngx_cc.channels      : channel list
ngx_cc.cluster       : cluster infomation
ngx_cc.invokes()     : internal invoker

# ngx_cc version 1.x
ngx_cc:new()         : create communication channel and return its route
ngx_cc.optionAgain() : options generater of ngx_cc.cc()
ngx_cc.optionAgain2(): a warp of optionAgain()
ngx_cc.say()         : output http responses

# ngx_cc version 2.x
ngx_cc.self()        : warp of ngx.location.capture(), send sub-request to myself with current context
route.remote()       : remote procedure call(RPC) for multi-root architecture, base RESTApi or direct http request
ngx_cc.transfer()    : online transfer some clients to new super
ngx_cc.all()         : batch communication request, call and return once, ngx.thread based
```

###### >> ngx_cc:new
> function ngx_cc:new(channel, options)

try get a route instance workat 'test' channel, and with default options:
```lua
route = ngx_cc:new('test')
```
the default options is:
```lua
options = {
    host = '127.0.0.1',
    port = '80',
    dict = 'test_dict',     -- 'channel_name' .. '_dict'
    initializer = 'automatic'
}
```
you can put custom options, ex:
```lua
route = ngx_cc:new('test', { port = '90' })
```

###### >> ngx_cc.say
> function ngx_cc.say(r_status, r_resps)

print/write context into current http responses with a route.cc() communication:
```lua
ngx_cc.say(route.cc('/_/invoke'))
```
for 'workers'/'clients' direction, will output all response body of success communication.

###### >> ngx_cc.self and ngx_cc.remote
> function ngx_cc.self(url, opt)
>
> function ngx_cc.remote(url, opt)

ngx_cc.self() will send a sub-request from current request context. it's warp of ngx.location.capture*, with same interface of route.cc().

ngx_cc.remote() will send a rpc(remote process call). so, the full remote url is required for 'url' parament.

> ngx_cc.self/remote is **none channel dependency**, so you can call them without communication channel.
> ngx_cc.self() unsupport '_' replacement symbol, but route.self() is supported.

###### >> ngx_cc.transfer
> function ngx_cc.transfer(super, channels, clients)

```
paraments:
	super    - string, 'HOST:PORT'
	channels - string, 'channelName1,channelName2,...', or '*'
	clients  - string, 'ip1,ip2,ip3,...', or '*'
```
Transfer these **clients** to new **super** at these **channels**. the api will rewrite clients register table in shared dictionary, and send transfer command to these **clients**.

**clients** will invoke the command and transfer himself.

###### >> ngx_cc.all
> function ngx_cc.all(requests, comment)  -- comment is log only

ngx_cc.all() will batch send all requests. the request define:
> { cc_command, arg1, arg2, ... }

so, you can push any command/call, ex:
```lua
local reuests = {}
table.insert(reuests, {ngx_cc.remote, 'a_url', a_option_table})
table.insert(reuests, {ngx_cc.all, request2})
table.insert(reuests, {route.cc, 'a_url', a_option_table})

local ok, resps = ngx_cc.all(reuests)
ngx_cc.say(ok, resps)
```
###### >> ngx_cc.invokes
> function ngx_cc.invokes(channel, master_only)

will call from localtions in nginx.conf only:
```conf
# invoke at worker listen port
location ~ ^/([^/]+)/invoke {
    content_by_lua 'ngx_cc.invokes(ngx.var[1])';
}

# hub at main listen port(80), will redirect to route listen port
location ~ ^/([^/]+)/hub {
    content_by_lua 'ngx_cc.invokes(ngx.var[1], true)';
}
```

###### >> ngx_cc.optionAgain and ngx_cc.optionAgain2
> function ngx_cc.optionAgain(direction, opt)

> function ngx_cc.optionAgain2(direction, opt, force_mix_into_current)

the 'opt' parament see: options of [ngx.location.capture*](http://wiki.nginx.org/HttpLuaModule#ngx.location.capture)

the 'direction' parament is string(will copy to opt.direction):
```lua
--  'super'  : 1:1  send to super node, the super is parent node.
--  'master' : 1:1  send to router process from any worker
--  'workers': 1:*  send to all workers
--  'clients': 1:*  send to all clients
```
Usage:
> * function ngx_cc.optionAgain()
> * function ngx_cc.optionAgain('direction')
> * function ngx_cc.optionAgain(direction_object)
> * function ngx_cc.optionAgain(direction_object, opt)

 examples:
```lua
-- case 1
route.cc('/_/invoke', ngx_cc.optionAgain())
```
will return default option object:
```lua
default_opt = {
    direction = 'master',  -- default
    method = ngx.req.get_method(),
    args   = ngx.req.get_uri_args(),
    body   = ngx.req.get_body_data()
}
```
and,
```lua
-- case 2
route.cc('/_/invoke', ngx_cc.optionAgain('clients'))
```
will return default option object, but opt.direction is 'clients'.

```lua
-- case 3
ngx_cc.optionAgain({
    direction = 'super',
    body = ''
})
```
will mix these options
* { direction = 'super', body = '' }

into default option object.
```lua
-- case 4
ngx_cc.optionAgain({
    direction = 'super',
    args = {
        tryDoSomething = false,
        doSomething = true
    }
}, {
    method = 'POST',
    body = ''
})
```
will get mixed options beetwen direction_object and opt, but default_option_object is ignored.

### route APIs
```
# internal
route.cluster        : cluster infomation for current worker process

# inherited from ngx_cc
route.say()          : see: ngx_cc.say()
route.self()         : see: ngx_cc.self(), support '_' replacement symbol
route.remote()       : see: ngx_cc.remote()
route.optionAgain()  : see: ngx_cc.optionAgain()
route.optionAgain2() : see: ngx_cc.optionAgain2()

# ngx_cc version 1.x
route.cc()           : main communication function, support directions: super/master/clients/workers
route.cast()         : communication at 'workers' direction only
route.isRoot()       : utility，check root node for current
route.isInvokeAtMaster() : utility，check master/router node for current, and force communication invoke at 'master'

# ngx_cc version 2.x
route.isInvokeAtPer() : utility，check current is worker node, and force communication invoke at 'workers'
route.transfer()      : override ngx_cc.transfer(), transfer current worker only.
```
###### >> route.cc and route.cast
> function route.cc(url, opt)

> function route.cast(url, opt)

the 'url' parament include pattens:
```
'/_/invoke'           : a action invoking, the action_name setting in options
'/_/invoke/ding'      : a remote call with uri '/ding'
'/_/cast/ding'        : a remote call with uri '/ding', and target service will boardcast the message.
'/_/_/test/invokeXXX' : a sub-channel 'XXX' invoke at 'test' channel
```
the 'opt' parament see: [ngx_cc.optionAgain](https://github.com/aimingoo/ngx_cc/blob/master/README.md#-ngx_ccoptionagain-and-ngx_ccoptionagain2)

if you want send 'AAA' as action_name for all 'workers', the communication implement by these codes:
```lua
route.cc('/_/invoke', {
	direction = 'workers',
	args = { AAA = true }
})

-- OR

route.cc('/_/invoke?AAA', { direction = 'workers' })
```
and, if you want copy all from current request context(ngx.vars/ctx/body...), ex:
```lua
route.cc('/_/invoke?AAA', ngx_cc.optionAgain('workers'))
```

###### >> route.self and route.remote
> function route.self(url, opt)

> function route.remote(url, opt)

route.self() will send a sub-request from current request context. it's warp of ngx.location.capture*, with same interface of route.cc().

route.remote() will send a rpc(remote process call). so, the full remote url is required for 'url' parament.

###### >> route.isRoot()
> function route.isRoot()

check root node for current process. equivlant to:
> * cluster.master.host == cluster.super.host

> and
> * cluster.master.port == cluster.super.port

if current is root node, then route.cc() with "direction = 'super'" will ignored, and return:
> * r_status, r_resps = true, {}

###### >> route.isInvokeAtMaster()
> function route.isInvokeAtMaster()

if current is master, then isInvokeAtMaster() return true only. else, will return false and re-send current request to real master/route node.

the function will force invoke at 'master/router' of current communication always. there is simple example, try it in your invoke code:
```lua
route.invoke.XXX = function()
	local no_redirected, r_status, r_resps = route.isInvokeAtMaster()
	if no_redirected then
		...  -- your process for action XXX
	else
		route.say(r_status, r_resps)
	end
end
```
###### >> route.isInvokeAtPer()
> function route.isInvokeAtPer()

if current worker is listen at per-worker port, then isInvokeAtPer() return true only. else, will return false and re-send current request to real all per-workers.

the function will force invoke at 'workers' of current communication always. so will try request for per-workers, **and** process same action by per-worker. there is simple example, try it in your invoke code:
```lua
route.invoke.XXX = function()
	local no_redirected, r_status, r_resps = route.isInvokeAtPer()
	if no_redirected then
		...  -- your process for action XXX
	else
		route.say(r_status, r_resps)
	end
end
```
another, a real case in module/invoke.lua.
## History
```text
2015.11.03	release v2.1.0, publish NGX_CC node as N4C resources
	- supported N4C resource management (setting "n4c_supported" in ngx_cc.lua) and high performance node list access
	- supported N4C distribution node management
	- supported master/worker process crash check and dynamic restore
	- procfs_process.lua removed, get parent_pid by LuaJIT now
	- status check is safe&correct by HTTP_SUCCESS()

2015.08.13	release v2.0.0, support NGX_4C programming architecture
	- single shared dictionary multi channels
	- custom headers when pass_proxy or ngx.location.capture (require NGX_4C framework)
	- support super/client nodes online/dynamic transfer in cluster
	- support cluster/node invalid check (require module/invalid.lua)
		- single node invalid, will restart and put it to cluster
		- super invalid, will waiting and try reconnection
		- clients and workers invalid, will report to master of channel and try remove it
	- add api
		- route.isInvokeAtPer()
		- ngx_cc.all(), ngx_cc.transfer(), ngx_cc.remote(), ngx_cc.self()
	- update ngx_cc core framework
		- requestSelf_BASH/requestSelf_DIRECT/requestSelf_CC is optional
		- ssl port 433 is protected
	- BUGFIX: post body lost
	- UPDATE: standard/sample nginx.conf

2015.02		release v1.0.0
```