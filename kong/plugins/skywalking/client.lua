--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--    http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local socket = require "socket"
local cjson = require('cjson.safe')
local Span = require('skywalking.span')
local TC = require('skywalking.tracing_context')
local Segment = require('skywalking.segment')

local SEGMENT_BATCH_COUNT = 100
local log = kong.log
local timer_wakeup_seconds = 3
local config_hashes = {}
local has_segments = false
local merge_config = 0
local ngx_timer_every = ngx.timer.every

local Client = {}

key = ""
local function PrintTable(table , level)
    level = level or 1
    local indent = ""
    for i = 1, level do
        indent = indent.."  "
    end

    if key ~= "" then
        log.debug(indent..key.." ".."=".." ".."{")
    else
        log.debug(indent .. "{")
    end

    key = ""
    for k,v in pairs(table) do
        log.debug("-----")
        if type(v) == "table" then
            key = k
            PrintTable(v, level + 1)
        else
            local content = string.format("%s%s = %s", indent .. "  ",tostring(k), tostring(v))
            log.debug(content)
        end
    end
    log.debug(indent .. "}")

end

local function report_service_instance(config)
    local reportInstance = require("skywalking.management").newReportInstanceProperties(config.service_name, config.service_instance_name)
    local reportInstanceParam, err = cjson.encode(reportInstance)
    if not reportInstanceParam then
        log.err("[skywalking] Request to report instance fails, ", err)
        return
    end

    local http = require('resty.http')
    local httpc = http.new()
    local res, err = httpc:request_uri(config.backend_http_uri .. '/v3/management/reportProperties', {
        method = "POST",
        body = reportInstanceParam,
        headers = {
            ["Content-Type"] = "application/json",
        },
    })

    if not res then
        log.err("Instance report fails, ", err)
    elseif res.status == 200 then
        log.debug("[skywalking] Instance report response = ", res.body)
        local hash_key = config.application_id
        config_hashes[hash_key]["instancePropertiesSubmitted"] = true
    else
        log.err("[skywalking] Instance report fails, response code ", res.status)
    end
end

-- Ping the backend to update instance heartheat
local function ping(configuration)
    local pingPkg = require("skywalking.management").newServiceInstancePingPkg(configuration.service_name, configuration.service_instance_name)
    local pingPkgParam, err = cjson.encode(pingPkg)
    if not pingPkgParam then
        log.err("[skywalking] Agent ping fails, ", err)
    end

    local http = require('resty.http')
    local httpc = http.new()
    local res, err = httpc:request_uri(configuration.backend_http_uri .. '/v3/management/keepAlive', {
        method = "POST",
        body = pingPkgParam,
        headers = {
            ["Content-Type"] = "application/json",
        },
    })

    if err == nil then
        if res.status ~= 200 then
            log.err("[skywalking] Agent ping fails, response code ", res.status)
        end
    else
        log.err("[skywalking] Agent ping fails, ", err)
    end
end

-- Send segemnts data to backend
local function send_segments(segmentTransform, backend_http_uri)
    local http = require('resty.http')
    local httpc = http.new()
    log.debug("Segment report, request body ", segmentTransform)
    local res, err = httpc:request_uri(backend_http_uri .. '/v3/segments', {
        method = "POST",
        body = segmentTransform,
        headers = {
            ["Content-Type"] = "application/json",
        },
    })

    if err == nil then
        if res.status ~= 200 then
            log.err("Segment report fails, response code ", res.status)
            return false
        end
    else
        log.err("Segment report fails, ", err)
        return false
    end

    return true
end

-- Report trace segments to the backend
local function report_traces(queue, configuration, start_time)
    if #queue > 0 and ((socket.gettime()*1000 - start_time) <= math.min(configuration.max_callback_time_spent, timer_wakeup_seconds * 500)) then
        log.debug("[skywalking] Sending segments to skywalking oap")
        local counter = 0
        local batch_segments = {}
        repeat
            local segment = table.remove(queue)
            counter = counter + 1
            table.insert(batch_segments, segment)
            if (#batch_segments == SEGMENT_BATCH_COUNT) then
                send_segments(cjson.encode(batch_segments), configuration.backend_http_uri)
            else if(#queue ==0 and #batch_segments > 0) then
                send_segments(cjson.encode(batch_segments), configuration.backend_http_uri)
                batch_segments = {}
            end
            end
        until counter == SEGMENT_BATCH_COUNT or next(queue) == nil

        if #queue > 0 then
            has_segments = true
        else
            has_segments = false
        end
    else
        has_segments = false
        if #queue <= 0 then
            log.debug("[skywalking] Queue is empty, no segments to send ")
        else
            log.debug("[skywalking] Max callback time exceeds, skip sending segments now ")
        end
    end
end

local function send_segments_batch(premature)
    if premature then
        return
    end
    local start_time = socket.gettime()*1000
    repeat
        for k, v in pairs(skywalking_queue_hashes) do
            log.debug("[skywalking] send_segments_batch hash_key :", k, ", skywalking_queue_hashes : ", cjson.encode(v))
        end
        for key, queue in pairs(skywalking_queue_hashes) do
            log.debug("[skywalking] key : ", key)
            local config = config_hashes[key]
            if not config then
                log.debug("[skywalking] Skipping sending segments to skywalking oap, since no configuration is available yet")
                return
            end

            if (config.instancePropertiesSubmitted == nil or config.instancePropertiesSubmitted == false) then
                report_service_instance(config)
            else
                ping(config)
            end

            if #queue > 0 and ((socket.gettime()*1000 - start_time) <= math.min(config.max_callback_time_spent, timer_wakeup_seconds * 500)) then
                log.debug("[skywalking] Sending segments to skywalking oap")

                report_traces(queue, config, start_time)
            else
                has_segments = false
                if #queue <= 0 then
                    log.debug("[skywalking] Queue is empty, no segments to send ")
                else
                    log.debug("[skywalking] Max callback time exceeds, skip sending segments now ")
                end
            end
        end
    until has_segments == false

    local endtime = socket.gettime()*1000

    log.debug("[skywalking] send segments batch took time - ".. tostring(endtime - start_time).." for pid - ".. ngx.worker.pid())
end

local function prepare_for_report(hash_key)
    local entrySpan = ngx.ctx.entrySpan
    if not entrySpan then
        return
    end

    local ngxstatus = ngx.var.status
    Span.tag(entrySpan, 'http.status', ngxstatus)
    if tonumber(ngxstatus) >= 500 then
        Span.errorOccurred(entrySpan)
    end

    Span.finish(entrySpan, ngx.now() * 1000)

    local ok, segment = TC.drainAfterFinished(ngx.ctx.tracingContext)
    if not ok then
        return
    end

    log.debug("[skywalking] prepareForReport hash_key : ", hash_key)
    table.insert(skywalking_queue_hashes[hash_key], Segment.transform(segment))
    log.debug("[skywalking] prepareForReport segmentJson : ", cjson.encode(skywalking_queue_hashes[hash_key]))
    for k, v in pairs(skywalking_queue_hashes) do
        log.debug("[skywalking] hash_key :", k, ", prepareForReport skywalking_queue_hashes : ", cjson.encode(v))
    end

end

function Client:execute(config)
    -- Hash key of the config application Id
    -- TODO There is no good way, unless you can get the plugin ID
    local hash_key = config.backend_http_uri
    log.debug("[skywalking] hash_key : ", hash_key)
    if config_hashes[hash_key] == nil then
        local app_configs = {}
        app_configs["instancePropertiesSubmitted"] = nil
        app_configs["application_id"] = hash_key
        config_hashes[hash_key] = app_configs
        skywalking_queue_hashes[hash_key] = {}
        for k,v in pairs(config) do
            config_hashes[hash_key][k] = v
        end
    end

    -- Merge user-defined and moesif configs as user-defined config could be change at any time
    merge_config = merge_config + 1
    if merge_config == 100 then
        for k,v in pairs(config) do
            config_hashes[hash_key][k] = v
        end
        merge_config = 0
    end
    log.debug("[skywalking] config memery address: ", config," config : ", cjson.encode(config))
    prepare_for_report(hash_key)
end

-- Schedule segments batch job
function Client:start_background_thread()
    log.debug("[skywalking] Scheduling segments batch job every ".. tostring(timer_wakeup_seconds).." seconds")

    -- TODO It's not a good idea. Every worker must have a timer
    --if 0 == ngx.worker.id() then
        local ok, err = ngx_timer_every(timer_wakeup_seconds, send_segments_batch)
        if not ok then
            log.err("[skywalking] Error when scheduling the job: "..err)
        end
    --end
end

return Client
