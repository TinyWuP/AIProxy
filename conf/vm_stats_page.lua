-- 统计API模块 (JSON格式)
-- 提供JSON格式的统计数据API
-- 基于 VictoriaMetrics 数据源，使用IP地址连接

local cjson = require "cjson"
local vm_stats_api = require "vm_stats_api"

-- 获取统计数据（优雅降级）
local function get_stats()
    -- 首先尝试从 VictoriaMetrics 获取数据
    local ok, stats_data = pcall(vm_stats_api.get_stats)
    if ok and stats_data and not stats_data.error then
        return stats_data
    end
    
    ngx.log(ngx.WARN, "VictoriaMetrics 数据获取失败，使用传统统计数据")
    
    -- 降级到传统的共享内存统计
    local stats = ngx.shared.stats
    if not stats then
        return {
            error = "统计数据不可用", 
            data_source = "none",
            timestamp = ngx.time()
        }
    end
    
    -- 基础统计
    local total_requests = stats:get("total_requests") or 0
    local successful_requests = stats:get("successful_requests") or 0
    local failed_requests = stats:get("failed_requests") or 0
    local start_time = stats:get("start_time") or ngx.time()
    local last_request_time = stats:get("last_request_time") or 0
    local total_response_time = stats:get("total_response_time") or 0
    
    -- 协议类型统计
    local http_requests = stats:get("http_requests") or 0
    local websocket_requests = stats:get("websocket_requests") or 0
    local websocket_connections = stats:get("websocket_connections") or 0
    
    -- 渠道统计（从传统方法获取）
    local channel_stats = {}
    if _G.open_config_file then
        local file = _G.open_config_file("conf/channels_config.json")
        if file then
            local content = file:read("*all")
            file:close()
            local ok, config = pcall(cjson.decode, content)
            if ok and config.channels then
                for channel_id, channel_info in pairs(config.channels) do
                    local channel_key = "channel_" .. channel_info.name .. "_requests"
                    local channel_requests = stats:get(channel_key) or 0
                    channel_stats[channel_id] = {
                        name = channel_info.name,
                        requests = channel_requests,
                        status = channel_info.status
                    }
                end
            end
        end
    end
    
    -- 用户调用统计
    local user_stats = {}
    if _G.api_keys then
        for _, keyinfo in ipairs(_G.api_keys) do
            local user_name = keyinfo.name or "unknown"
            local description = keyinfo.description or ""
            local user_key = "user_" .. user_name .. "_requests"
            local user_requests = stats:get(user_key) or 0
            table.insert(user_stats, {
                name = user_name,
                proxy_key_display = string.sub(keyinfo.proxy_key or "", 1, 8) .. "...",
                description = description,
                requests = user_requests
            })
        end
    end
    
    -- 计算统计值
    local avg_response_time = 0
    if total_requests > 0 and total_response_time > 0 then
        avg_response_time = total_response_time / total_requests
    end
    
    local success_rate = 0
    if total_requests > 0 then
        success_rate = (successful_requests / total_requests) * 100
    end
    
    local uptime_seconds = ngx.time() - start_time
    
    local websocket_connection_rate = 0
    if websocket_requests > 0 then
        websocket_connection_rate = (websocket_connections / websocket_requests) * 100
    end
    
    return {
        service = "AIProxy",
        version = "2.0.0",
        uptime_seconds = uptime_seconds,
        
        total_requests = total_requests,
        successful_requests = successful_requests,
        failed_requests = failed_requests,
        success_rate = success_rate,
        
        protocol_stats = {
            http_requests = http_requests,
            websocket_requests = websocket_requests,
            websocket_connections = websocket_connections,
            websocket_connection_rate = websocket_connection_rate
        },
        
        channel_stats = channel_stats,
        user_stats = user_stats,
        
        avg_response_time = avg_response_time,
        last_request_time = last_request_time,
        
        api_keys_count = #(_G.api_keys or {}),
        timestamp = ngx.time(),
        
        data_source = "fallback"
    }
end

-- 设置响应头
ngx.header["Content-Type"] = "application/json; charset=utf-8"
ngx.header["Access-Control-Allow-Origin"] = "*"
ngx.header["Cache-Control"] = "no-cache, no-store, must-revalidate"

-- 获取统计数据并返回JSON
local stats_data = get_stats()

-- 如果有错误，返回错误信息
if stats_data.error then
    ngx.status = 500
    ngx.say(cjson.encode({
        error = stats_data.error,
        message = "统计数据获取失败",
        timestamp = stats_data.timestamp or ngx.time(),
        data_source = stats_data.data_source or "unknown"
    }))
else
    ngx.say(cjson.encode(stats_data))
end