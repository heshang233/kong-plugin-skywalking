--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local sw_client = require "skywalking.client"
local sw_tracer = require "skywalking.tracer"

local SkyWalkingHandler = {
  VERSION = "0.3.0",
  -- We want to run first so that timestamps taken are at start of the phase
  -- also so that other plugins might be able to use our structures
  PRIORITY = 100000,
}

local function get_conf(self)
    -- for some reason init_worker does *not* get the plugins `conf` as parameter, see https://github.com/Kong/kong/issues/3001
    -- see also: https://discuss.konghq.com/t/custom-plugin-access-plugin-configuration-from-init-worker/4445
    local key = kong.db.plugins:cache_key("skywalking", nil, nil, nil)
    local plugin, err = kong.cache:get(key, nil, function(key)
      local row, err = kong.db.plugins:select_by_cache_key(key)
      if err then
        return nil, tostring(err)
      end
      return row
    end, key)
    if err then
      ngx.log(ngx.ERR, "err in (pre-)fetching plugin ", self._name, " config:", err)
      return nil, err
    end
    return plugin.config, nil
end

function SkyWalkingHandler:init_worker()
  local config, err = get_conf(self)
  local metadata_buffer = ngx.shared.tracing_buffer

  metadata_buffer:set('serviceName', config.service_name)
  -- Instance means the number of Nginx deloyment, does not mean the worker instances
  if config.cluster_flag and hostname ~= nil then
    -- set hostname to service_instance_name
    config.service_instance_name = hostname
  end
  metadata_buffer:set('serviceInstanceName', config.service_instance_name)

  require("skywalking.util").set_randomseed()
  require("skywalking.client"):startBackendTimer(config.backend_http_uri)

end

function SkyWalkingHandler:rewrite(config)


  kong.ctx.plugin.skywalking_sample = false
  if config.sample_ratio == 1 or math.random() < config.sample_ratio then
      kong.ctx.plugin.skywalking_sample = true
      sw_tracer:start("upstream service")
  end
end

function SkyWalkingHandler:body_filter(config)
  if kong.ctx.plugin.skywalking_sample and ngx.arg[2] then
    sw_tracer:finish()
  end
end

function SkyWalkingHandler:log(config)
  if kong.ctx.plugin.skywalking_sample then
    sw_tracer:prepareForReport()
  end
end

return SkyWalkingHandler