-- VictoriaMetrics 统计API模块
-- 从 VictoriaMetrics 查询统计数据并提供API接口
-- 使用 cosocket 替代 resty.http

local cjson = require "cjson"

local _M = {}

-- VictoriaMetrics 查询配置
local VM_HOST = "victoriametrics"  -- 使用容器名称（DNS已修复）
local VM_BACKUP_HOST = "172.31.0.2"  -- 备用IP地址
local VM_PORT = 8428
local VM_QUERY_PATH = "/api/v1/query"
local VM_QUERY_RANGE_PATH = "/api/v1/query_range"
local VM_TIMEOUT = 10000  -- 10秒超时

-- 使用 cosocket 执行 PromQL 查询
local function query_vm_cosocket(promql, time_param)
    local sock = ngx.socket.tcp()
    sock:settimeout(VM_TIMEOUT)
    
    -- 首先尝试容器名称，失败后尝试备用IP
    local hosts_to_try = {VM_HOST, VM_BACKUP_HOST}
    local connected = false
    local last_error = nil
    
    for _, host in ipairs(hosts_to_try) do
        local ok, err = sock:connect(host, VM_PORT)
        if ok then
            connected = true
            ngx.log(ngx.DEBUG, "成功连接到VictoriaMetrics: ", host)
            break
        else
            last_error = err
            ngx.log(ngx.DEBUG, "连接失败 ", host, ": ", err)
        end
    end
    
    if not connected then
        ngx.log(ngx.ERR, "连接VictoriaMetrics失败，所有主机都不可达: ", last_error)
        return nil, last_error
    end
    
    -- 构建查询参数
    local params = {
        query = promql
    }
    
    if time_param then
        params.time = time_param
    end
    
    local query_string = {}
    for k, v in pairs(params) do
        table.insert(query_string, k .. "=" .. ngx.escape_uri(tostring(v)))
    end
    
    local query_path = VM_QUERY_PATH .. "?" .. table.concat(query_string, "&")
    
    -- 构建HTTP请求
    local request = table.concat({
        "GET " .. query_path .. " HTTP/1.1",
        "Host: " .. VM_HOST .. ":" .. VM_PORT,
        "Accept: application/json",
        "Connection: close",
        "",
        ""
    }, "\r\n")
    
    local bytes, err = sock:send(request)
    if not bytes then
        ngx.log(ngx.ERR, "发送查询到VictoriaMetrics失败: ", err)
        sock:close()
        return nil, err
    end
    
    -- 读取响应状态行
    local status_line, err = sock:receive()
    if not status_line then
        ngx.log(ngx.ERR, "读取VictoriaMetrics响应状态失败: ", err)
        sock:close()
        return nil, err
    end
    
    -- 检查HTTP状态码
    local status_code = status_line:match("HTTP/%d+%.%d+ (%d+)")
    if status_code ~= "200" then
        sock:close()
        return nil, "HTTP " .. (status_code or "unknown")
    end
    
    -- 读取响应头
    local content_length = 0
    while true do
        local line, err = sock:receive()
        if not line then
            sock:close()
            return nil, "读取响应头失败: " .. (err or "")
        end
        
        if line == "" then
            break  -- 空行表示头部结束
        end
        
        local length = line:match("Content%-Length: (%d+)")
        if length then
            content_length = tonumber(length)
        end
    end
    
    -- 读取响应体
    local body = ""
    if content_length > 0 then
        body, err = sock:receive(content_length)
        if not body then
            sock:close()
            return nil, "读取响应体失败: " .. (err or "")
        end
    else
        -- 如果没有Content-Length，尝试读取到连接关闭
        while true do
            local chunk, err = sock:receive(1024)
            if not chunk then
                break
            end
            body = body .. chunk
        end
    end
    
    sock:close()
    
    -- 解析JSON响应
    local ok, data = pcall(cjson.decode, body)
    if not ok then
        ngx.log(ngx.ERR, "解析VictoriaMetrics响应失败: ", data)
        return nil, "JSON解析错误"
    end
    
    if data.status ~= "success" then
        ngx.log(ngx.ERR, "VictoriaMetrics查询失败: ", data.error or "未知错误")
        return nil, data.error or "查询失败"
    end
    
    return data.data, nil
end

-- 执行 PromQL 查询（优雅降级）
local function query_vm(promql, time_param)
    local data, err = query_vm_cosocket(promql, time_param)
    if data then
        return data, nil
    end
    
    -- 如果VictoriaMetrics查询失败，记录错误但不中断
    ngx.log(ngx.WARN, "VictoriaMetrics查询失败，将使用降级数据: ", err or "未知错误")
    return nil, err
end

-- 获取单个指标值
local function get_single_value(promql, default_value)
    local data, err = query_vm(promql)
    if not data or not data.result or #data.result == 0 then
        return default_value or 0
    end
    
    local result = data.result[1]
    if result and result.value and #result.value > 1 then
        return tonumber(result.value[2]) or (default_value or 0)
    end
    
    return default_value or 0
end

-- 获取带标签的指标列表
local function get_labeled_values(promql)
    local data, err = query_vm(promql)
    if not data or not data.result then
        return {}
    end
    
    local results = {}
    for _, item in ipairs(data.result) do
        if item.value and #item.value > 1 then
            table.insert(results, {
                labels = item.metric or {},
                value = tonumber(item.value[2]) or 0
            })
        end
    end
    
    return results
end

-- 格式化运行时间
local function format_uptime(seconds)
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    
    if days > 0 then
        return string.format("%d天 %d小时 %d分钟", days, hours, minutes)
    elseif hours > 0 then
        return string.format("%d小时 %d分钟", hours, minutes)
    elseif minutes > 0 then
        return string.format("%d分钟 %d秒", minutes, secs)
    else
        return string.format("%d秒", secs)
    end
end

-- 格式化时间戳
local function format_timestamp(timestamp)
    if timestamp == 0 then
        return "从未"
    end
    return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

-- 加载渠道配置（复用原有逻辑）
local function load_channels_config()
    local file = _G.open_config_file("conf/channels_config.json")
    if not file then
        return {}
    end
    
    local content = file:read("*all")
    file:close()
    
    local ok, config = pcall(cjson.decode, content)
    if not ok then
        return {}
    end
    
    return config.channels or {}
end

-- 获取统计数据
function _M.get_stats()
    -- 系统基础信息
    local uptime = get_single_value("aiproxy_uptime_seconds", 0)
    local api_keys_count = get_single_value("aiproxy_api_keys_total", #(_G.api_keys or {}))
    
    -- 请求统计 - 使用5分钟内的数据
    local total_requests = get_single_value("sum(increase(aiproxy_requests_total[24h]))", 0)
    local successful_requests = get_single_value('sum(increase(aiproxy_requests_total{status="success"}[24h]))', 0)
    local failed_requests = total_requests - successful_requests
    
    -- 协议统计
    local http_requests = get_single_value('sum(increase(aiproxy_requests_total{protocol="http"}[24h]))', 0)
    local websocket_requests = get_single_value('sum(increase(aiproxy_requests_total{protocol="websocket"}[24h]))', 0)
    local websocket_connections = get_single_value("sum(increase(aiproxy_websocket_connections_total[24h]))", 0)
    
    -- 平均响应时间
    local avg_response_time_data = query_vm('sum(aiproxy_response_time_seconds) / sum(aiproxy_requests_total)')
    local avg_response_time = "0.000"
    if avg_response_time_data and avg_response_time_data.result and #avg_response_time_data.result > 0 then
        local result = avg_response_time_data.result[1]
        if result and result.value and #result.value > 1 then
            avg_response_time = string.format("%.3f", tonumber(result.value[2]) or 0)
        end
    end
    
    -- 计算成功率
    local success_rate = 0
    if total_requests > 0 then
        success_rate = (successful_requests / total_requests) * 100
    end
    
    -- WebSocket连接率
    local websocket_connection_rate = 0
    if websocket_requests > 0 then
        websocket_connection_rate = (websocket_connections / websocket_requests) * 100
    end
    
    -- 渠道统计
    local channel_stats = {}
    local channels_config = load_channels_config()
    if next(channels_config) then
        local channel_metrics = get_labeled_values('sum(increase(aiproxy_requests_total[24h])) by (channel)')
        
        for _, metric in ipairs(channel_metrics) do
            local channel_name = metric.labels.channel
            if channel_name and channel_name ~= "unknown" then
                -- 查找渠道配置
                local channel_info = nil
                for channel_id, config in pairs(channels_config) do
                    if config.name == channel_name then
                        channel_info = config
                        break
                    end
                end
                
                channel_stats[channel_name] = {
                    name = channel_name,
                    requests = metric.value,
                    status = channel_info and channel_info.status or "unknown"
                }
            end
        end
    end
    
    -- 用户调用统计
    local user_stats = {}
    local user_metrics = get_labeled_values('sum(increase(aiproxy_requests_total[24h])) by (user_name)')
    
    for _, metric in ipairs(user_metrics) do
        local user_name = metric.labels.user_name
        if user_name and user_name ~= "unknown" then
            -- 查找用户描述和完整信息
            local description = ""
            local proxy_key_display = ""
            if _G.api_keys then
                for _, keyinfo in ipairs(_G.api_keys) do
                    if keyinfo.name == user_name then
                        description = keyinfo.description or ""
                        proxy_key_display = string.sub(keyinfo.proxy_key or "", 1, 8) .. "..."
                        break
                    end
                end
            end
            
            table.insert(user_stats, {
                name = user_name,
                proxy_key_display = proxy_key_display,
                description = description,
                requests = metric.value
            })
        end
    end
    
    -- 获取最后请求时间（从传统统计中获取，或使用当前时间）
    local stats = ngx.shared.stats
    local last_request_time = 0
    if stats then
        last_request_time = stats:get("last_request_time") or 0
    end
    
    return {
        service = "AIProxy",
        version = "2.0.0",
        uptime_seconds = uptime,
        uptime_formatted = format_uptime(uptime),
        
        total_requests = total_requests,
        successful_requests = successful_requests,
        failed_requests = failed_requests,
        success_rate = success_rate,
        
        http_requests = http_requests,
        websocket_requests = websocket_requests,
        websocket_connections = websocket_connections,
        websocket_connection_rate = websocket_connection_rate,
        
        channel_stats = channel_stats,
        user_stats = user_stats,
        
        avg_response_time = avg_response_time,
        last_request_time = last_request_time,
        last_request_formatted = format_timestamp(last_request_time),
        
        api_keys_count = api_keys_count,
        timestamp = ngx.time(),
        timestamp_formatted = format_timestamp(ngx.time()),
        
        -- 数据源标识
        data_source = "victoriametrics"
    }
end

-- 健康检查 - 检查VictoriaMetrics连接
function _M.health_check()
    local data, err = query_vm("up")
    if err then
        return {
            status = "error",
            message = "VictoriaMetrics连接失败: " .. err,
            timestamp = ngx.time()
        }
    end
    
    return {
        status = "ok",
        message = "VictoriaMetrics连接正常",
        timestamp = ngx.time()
    }
end

-- 获取历史数据（范围查询）
function _M.get_historical_data(metric, start_time, end_time, step)
    local httpc = http.new()
    httpc:set_timeout(VM_TIMEOUT)
    
    local params = {
        query = metric,
        start = start_time or (ngx.time() - 3600),  -- 默认1小时前
        ["end"] = end_time or ngx.time(),           -- 默认现在
        step = step or "60s"                        -- 默认1分钟间隔
    }
    
    -- 构建查询参数
    local query_string = {}
    for k, v in pairs(params) do
        table.insert(query_string, k .. "=" .. ngx.escape_uri(tostring(v)))
    end
    
    local url = VM_QUERY_RANGE_URL .. "?" .. table.concat(query_string, "&")
    
    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Accept"] = "application/json"
        }
    })
    
    if not res or res.status ~= 200 then
        return nil, err or ("HTTP " .. (res and res.status or "unknown"))
    end
    
    local ok, data = pcall(cjson.decode, res.body)
    if not ok or data.status ~= "success" then
        return nil, "数据解析失败"
    end
    
    return data.data, nil
end

return _M