# ngx_cc
A framework of Nginx Communication Cluster. reliable dispatch/translation messages in nginx nodes and processes.

The chinese intro document at here: [chinese wiki](https://github.com/aimingoo/ngx_cc/wiki/%E7%AE%80%E4%BB%8B).

The framework support:
> * communication between cluster nodes and worker processes, with directions: super/clients, master/workers
> * native coroutined ngx.location.capture* based
>  * without cosocket (not dependent)
> * multi channels and sub-channels supported
> * multi-root or cross-cluster communication supported

The contents of current document:
> * [environment](ngx_cc#environment)
> * [run testcase with ngx_cc](ngx_cc#run-testcase-with-ngx_cc)
> * [build cluster configures](ngx_cc#build-cluster-configures)
> * [programming](ngx_cc#programming-with-ngx_cc)
> * [APIs](ngx_cc#apis)
>  * [modules in the framework](ngx_cc#modules-in-the-framework)
>  * [locations in nginx.conf](ngx_cc#locations-in-nginxconf)
>  * [ngx_cc APIs](ngx_cc#ngx_cc-apis)
>  * [route APIs](ngx_cc#route-apis)

## environment
Requirements:
* nginx + lua
* per-worker-listener patch
* lua-process module (macosx only)

#### 1) install nginx+lua
OpenResty is commented(here)，or install nginx+lua, see:
> [http://wiki.nginx.org/HttpLuaModule#Installation](http://wiki.nginx.org/HttpLuaModule#Installation)

#### 2) install per-worker-listener patch
need install the patch before compile nginx+lua. ex:
```bash
    cd nginx-1.7.7/
    wget https://github.com/arut/nginx-patches/raw/master/per-worker-listener -O per-worker-listener.patch
    patch -p1 < per-worker-listener.patch

	# to compiling
	# ./configure --prefix=...
```
#### 3) install lua-process module
if run ngx_cc on MacOSX(procfs is unsupported), then you need install the module. see: 
> [https://github.com/mah0x211/lua-process](https://github.com/mah0x211/lua-process)

#### 4) test in the nginx environment
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
change search path of lua in nginx:
```bash
# get <PATH> of ngx_cc install directory
> cd ~/ngx_cc/
> pwd
/Users/aimingoo/work/ngx_cc

# replace <PATH> in these lines(for demo nginx.conf):
> grep -n 'aimingoo' nginx.conf
26:     lua_package_path '/Users/aimingoo/work/ngx_cc/?.lua;;';
27:     init_worker_by_lua_file '/Users/aimingoo/work/ngx_cc/init_worker.lua';
```
run testcase:
```bash
> sudo ./sbin/nginx -c ~/ngx_cc/nginx.conf
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
> sudo ./nginx -c ~/work/ngx_cc/nginx.conf.1
> sudo ./nginx -c ~/work/ngx_cc/nginx.conf.2
```
OK, now, you will get a cluster with next topology:

[[images/cluster_arch_4.png]]

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

		lua_shared_dict test_dict 10M;
```
the default dictionary name is:
> channel_name .. '_dict'

example:
> test_dict

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
procfs_process.lua  -- support process:ppid(), get parent_pid of current process
heartbeat.lua       -- (heartbeat module, optional)
invoke.lua          -- (getServiceStat action, optional)

> cd ../lib/
> ls
JSON.lua            -- JSON format output, dependency by getServiceStat action.
ngx_tasks.lua       -- task management, dependency by ngx_cc.tasks interface.
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
ngx_cc.tasks         : default tasks, drive by tasks management module/plugins, see module/heartbeat.lua or ngx_tasks project.
ngx_cc.channels      : channel list
ngx_cc.cluster       : cluster infomation
ngx_cc:new()         : create communication channel and return its route
ngx_cc.optionAgain() : options generater of ngx_cc.cc()
ngx_cc.optionAgain2(): a warp of optionAgain()
ngx_cc.say()         : output http responses
ngx_cc.invokes()     : internal invoker
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
route.cluster        : cluster infomation for current worker process
route.cc()           : main communication function, support directions: super/master/clients/workers
route.cast()         : communication at 'workers' direction only
route.self()         : warp of ngx.location.capture(), send sub-request with current context
route.remote()       : send request for remote node, it's RPC call for multi-root architecture
route.isRoot()       : utility，check root node for current
route.isInvokeAtMaster() : utility，check master/router node for current, and force communication invoke at 'master'
route.say()          : see: ngx_cc.say()
route.optionAgain()  : see: ngx_cc.optionAgain()
route.optionAgain2() : see: ngx_cc.optionAgain2()
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
the 'opt' parament see: ngx_cc.optionAgain

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

the function will force invoke at 'master/router' of current communication always. this is a simple example, try it in your invoke code:
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
