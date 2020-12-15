# kong-plugin-skywalking
The Nginx Lua agent 0.3.0 for Apache SkyWalking 8 kong-plugin

## 安装插件

#### 下载源码
```shell script
git clone https://github.com/heshang233/kong-plugin-skywalking.git
git checkout feature
```
#### 安装依赖
```shell script
luarocks install lua-resty-http
luarocks install lua-resty-jit-uuid
luarocks install skywalking-nginx-lua 0.3-0
```
#### 安装插件
```shell script
cd kong-plugin-skywalking
cp -r ./kong/plugins/skywalking/ /usr/local/share/lua/5.1/kong/plugins
```
#### 修改配置文件
```shell script
vi /etc/kong/kong.conf

...
nginx_http_lua_shared_dict=tracing_buffer 100m
plugins = bundled,skywalking-kong
...
```
