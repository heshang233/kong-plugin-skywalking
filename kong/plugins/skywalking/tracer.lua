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
local Span = require('skywalking.span')
local TC = require('skywalking.tracing_context')
local Layer = require('skywalking.span_layer')
local Segment = require('skywalking.segment')
local Util = require('skywalking.util')
local json = require('cjson.safe')
local log = kong.log

local metadata_shdict = ngx.shared.tracing_buffer
local ngx = ngx
local nginxComponentId = 6000


local Tracer = {}


function Tracer:start(config, upstream_name, correlation)
    --local serviceName = metadata_shdict:get("serviceName")
    --local serviceInstanceName = metadata_shdict:get('serviceInstanceName')
    local serviceName = config.service_name
    local serviceInstanceName = config.service_instance_name
    local tracingContext = TC.new(serviceName, serviceInstanceName)

    -- Constant pre-defined in SkyWalking main repo
    -- 6000 represents Nginx

    local contextCarrier = {}
    contextCarrier["sw8"] = ngx.var.http_sw8
    contextCarrier["sw8-correlation"] = ngx.var.http_sw8_correlation

    local time_now = ngx.now() * 1000
    local entrySpan = TC.createEntrySpan(tracingContext, ngx.var.uri, nil, contextCarrier)
    Span.start(entrySpan, time_now)
    Span.setComponentId(entrySpan, nginxComponentId)
    Span.setLayer(entrySpan, Layer.HTTP)

    Span.tag(entrySpan, 'http.method', ngx.req.get_method())
    Span.tag(entrySpan, 'http.params',
            ngx.var.scheme .. '://' .. ngx.var.host .. ngx.var.request_uri )

    contextCarrier = {}
    -- Use the same URI to represent incoming and forwarding requests
    -- Change it if you need.
    local upstreamUri = ngx.var.uri
    local upstreamServerName = upstream_name
    ------------------------------------------------------
    local exitSpan = TC.createExitSpan(tracingContext, upstreamUri, entrySpan,
            upstreamServerName, contextCarrier, correlation)
    Span.start(exitSpan, time_now)
    Span.setComponentId(exitSpan, nginxComponentId)
    Span.setLayer(exitSpan, Layer.HTTP)

    for name, value in pairs(contextCarrier) do
        ngx.req.set_header(name, value)
    end

    -- Push the data in the context
    local ctx = ngx.ctx
    ctx.tracingContext = tracingContext
    ctx.entrySpan = entrySpan
    ctx.exitSpan = exitSpan
end

function Tracer:finish()
    -- Finish the exit span when received the first response package from upstream
    if ngx.ctx.exitSpan ~= nil then
        local upstream_status = tonumber(ngx.var.upstream_status)
        if upstream_status then
            Span.tag(ngx.ctx.exitSpan, 'http.status', upstream_status)
        end
        Span.finish(ngx.ctx.exitSpan, ngx.now() * 1000)
        ngx.ctx.exitSpan = nil
    end
end

function Tracer:prepareForReport(config)
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

    local segmentJson, err = json.encode(Segment.transform(segment))
    if not segmentJson then
        ngx.log(ngx.ERR, "failed to encode segment: ", err)
        return
    end
    ngx.log(ngx.DEBUG, 'segment = ', segmentJson)

    local length, err = metadata_shdict:lpush('segment', segmentJson)
    if not length then
        ngx.log(ngx.ERR, "failed to push segment: ", err)
        return
    end
    ngx.log(ngx.DEBUG, 'segment buffer size = ', length)
end

return Tracer