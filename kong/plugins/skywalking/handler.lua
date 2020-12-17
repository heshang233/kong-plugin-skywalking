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

local sw_client = require "kong.plugins.skywalking.client"
local sw_tracer = require "kong.plugins.skywalking.tracer"
skywalking_queue_hashes = {}

local SkyWalkingHandler = {
    VERSION = "0.3.0",
    -- We want to run first so that timestamps taken are at start of the phase
    -- also so that other plugins might be able to use our structures
    PRIORITY = 100000,
}

function SkyWalkingHandler:init_worker()
    --require("skywalking.util").set_randomseed()
    sw_client:start_background_thread()

end

function SkyWalkingHandler:access(config)
    kong.ctx.plugin.skywalking_sample = false
    if config.sample_ratio == 1 or math.random() < config.sample_ratio then
        kong.ctx.plugin.skywalking_sample = true
        sw_tracer:start(config, "upstream service")
    end
end

function SkyWalkingHandler:body_filter(config)
    if kong.ctx.plugin.skywalking_sample and ngx.arg[2] then
        sw_tracer:finish()
    end
end

function log_event(config)
    sw_client:execute(config)
end

function SkyWalkingHandler:log(config)
    if kong.ctx.plugin.skywalking_sample then
        log_event(config)
    end
end

return SkyWalkingHandler