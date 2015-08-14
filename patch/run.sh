#!/bin/bash

##
## download and unpack nginx with lua, openresty is recommend
##
# curl -s 'https://openresty.org/download/ngx_openresty-1.7.10.2.tar.gz' | tar -xzv

##
## apply patchs
##		- support nginx 1.7x and ngx_lua 0.9x
##		- nginx 1.5+ is supported, plz force apply
##

cd ./ngx_openresty-1.7.*/bundle/nginx-1.7*/
patch -p2 < ../../../per-worker.patch
cd -

cd ./ngx_openresty-1.7.*/bundle/ngx_lua-0.9*/
patch -p2 < ../../../ngx-worker-port.patch
cd -