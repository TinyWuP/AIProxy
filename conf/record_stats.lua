-- 统计记录模块
-- 记录请求统计信息，支持HTTP和WebSocket协议
-- 同时支持传统Nginx共享内存和VictoriaMetrics

local vm_metrics = require "vm_metrics"
local cjson = require "cjson"

-- 根据proxy_key查找对应的name
local function get_user_name_by_proxy_key(proxy_key)
    if not proxy_key or not _G.api_keys then
        return "unknown"
    end
    
    for _, keyinfo in ipairs(_G.api_keys) do
        if keyinfo.proxy_key == proxy_key then
            return keyinfo.name or "unknown"
        end
    end
    
    return "unknown"
end

local function record_request_stats()
    local stats = ngx.shared.stats
    if not stats then
        ngx.log(ngx.ERR, "统计共享字典未初始化")
        return
    end
    
    -- 检查是否为内部管理页面，如果是则跳过统计
    local uri = ngx.var.uri
    if uri == "/stats" or uri == "/dashboard" or uri == "/favicon.ico" then
        ngx.log(ngx.DEBUG, "内部管理页面请求，跳过统计记录: " .. uri)
        return
    end
    
    -- 获取基本信息
    local status = ngx.status
    local request_time = tonumber(ngx.var.request_time) or 0
    local protocol_type = ngx.ctx.is_websocket and "WebSocket" or "HTTP"
    local channel_name = ngx.ctx.channel_name or "unknown"
    local proxy_key = ngx.ctx.proxy_key
    local model_name = ngx.ctx.model_name or "unknown"
    local request_size = tonumber(ngx.var.request_length) or 0
    local response_size = tonumber(ngx.var.bytes_sent) or 0
    
    -- 调试日志：记录收集到的统计信息
    ngx.log(ngx.INFO, "统计信息收集 - 渠道: " .. channel_name .. 
            ", 模型: " .. model_name .. 
            ", 协议: " .. protocol_type .. 
            ", 状态: " .. status)
    
    -- 确定状态类别
    local status_category = "unknown"
    if status >= 200 and status < 300 then
        status_category = "success"
    elseif status >= 400 and status < 500 then
        status_category = "client_error"
    elseif status >= 500 then
        status_category = "server_error"
    elseif status == 101 then
        status_category = "websocket_upgrade"
    end
    
    -- ===============================
    -- 1. 传统共享内存统计（保持兼容性）
    -- ===============================
    
    -- 更新总请求数
    local total_requests = stats:get("total_requests") or 0
    stats:set("total_requests", total_requests + 1)
    
    -- 更新协议类型统计
    local http_requests = stats:get("http_requests") or 0
    local websocket_requests = stats:get("websocket_requests") or 0
    
    if ngx.ctx.is_websocket then
        stats:set("websocket_requests", websocket_requests + 1)
        
        -- WebSocket连接统计
        if status == 101 then -- WebSocket握手成功
            local websocket_connections = stats:get("websocket_connections") or 0
            stats:set("websocket_connections", websocket_connections + 1)
            ngx.log(ngx.INFO, "WebSocket连接建立成功")
        end
    else
        stats:set("http_requests", http_requests + 1)
    end
    
    -- 更新成功/失败统计
    if status >= 200 and status < 400 then
        local successful_requests = stats:get("successful_requests") or 0
        stats:set("successful_requests", successful_requests + 1)
    else
        local failed_requests = stats:get("failed_requests") or 0
        stats:set("failed_requests", failed_requests + 1)
    end
    
    -- 更新渠道统计
    if channel_name ~= "unknown" then
        local channel_key = "channel_" .. channel_name .. "_requests"
        local channel_requests = stats:get(channel_key) or 0
        stats:set(channel_key, channel_requests + 1)
    end
 
    -- 统计每个用户（通过name标识）的调用次数
    local user_name = get_user_name_by_proxy_key(proxy_key)
    if user_name ~= "unknown" then
        local user_key = "user_" .. user_name .. "_requests"
        local user_requests = stats:get(user_key) or 0
        stats:set(user_key, user_requests + 1)
    end
        
    -- 更新响应时间统计
    local total_response_time = stats:get("total_response_time") or 0
    local new_total_time = total_response_time + request_time
    stats:set("total_response_time", new_total_time)
    
    -- 记录最后请求时间
    stats:set("last_request_time", ngx.time())
    
    -- ===============================
    -- 2. VictoriaMetrics 指标采集
    -- ===============================
    
    local request_data = {
        channel_name = channel_name,
        proxy_key = proxy_key,
        user_name = user_name,  -- 添加用户名字段
        model_name = model_name,
        is_websocket = ngx.ctx.is_websocket or false,
        status = status,
        status_category = status_category,
        response_time = request_time,
        request_size = request_size,
        response_size = response_size
    }
    
    -- 异步发送指标到VictoriaMetrics（避免影响请求性能）
    local ok, err = pcall(vm_metrics.record_request, request_data)
    if not ok then
        ngx.log(ngx.ERR, "发送VictoriaMetrics指标失败: ", err)
    end
    
    -- 记录日志
    ngx.log(ngx.INFO, "记录请求统计: 协议=" .. protocol_type .. 
            ", 渠道=" .. channel_name .. 
            ", 状态=" .. status .. 
            ", 耗时=" .. request_time)
end

record_request_stats() 