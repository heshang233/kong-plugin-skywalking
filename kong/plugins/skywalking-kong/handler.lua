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

function SkyWalkingHandler:init_worker(config)
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
  kong.log.info('access phase of skywalking plugin')
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