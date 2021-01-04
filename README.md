# kong-plugin-skywalking
The Nginx Lua agent 0.3.0 for Apache SkyWalking 8 kong-plugin

## 安装插件


#### 安装依赖
```shell script
luarocks install lua-resty-http
luarocks install lua-resty-jit-uuid
luarocks install skywalking-nginx-lua 0.3-0
```
#### 安装插件
```shell script
luarocks install kong-plugin-skywalking
```
#### 修改配置文件
```shell script
vi /etc/kong/kong.conf

...
plugins = bundled,skywalking
...
```
sss