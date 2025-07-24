-- VictoriaMetrics 指标采集模块
-- 将请求统计数据发送到 VictoriaMetrics
-- 使用 ngx.timer 和 cosocket 实现异步HTTP请求

local cjson = require "cjson"

local _M = {}

-- VictoriaMetrics 配置
local VM_HOST = "victoriametrics"  -- 使用容器名称（DNS已修复）
local VM_BACKUP_HOST = "172.31.0.2"  -- 备用IP地址
local VM_PORT = 8428
local VM_PATH = "/api/v1/import/prometheus"
local VM_TIMEOUT = 5000  -- 5秒超时

-- 获取当前时间戳（毫秒）
local function get_timestamp_ms()
    return ngx.time() * 1000
end

-- 构建 Prometheus 格式的指标
local function build_metric(name, labels, value, timestamp)
    local label_str = ""
    if labels and next(labels) then
        local label_pairs = {}
        for k, v in pairs(labels) do
            -- 清理标签值，避免特殊字符
            local clean_value = tostring(v):gsub('"', '\\"'):gsub('\n', ' ')
            table.insert(label_pairs, k .. '="' .. clean_value .. '"')
        end
        label_str = "{" .. table.concat(label_pairs, ",") .. "}"
    end
    
    return string.format("%s%s %s %d", name, label_str, tostring(value), timestamp or get_timestamp_ms())
end

-- 使用cosocket发送指标到 VictoriaMetrics
local function send_metrics_cosocket(metrics)
    if not metrics or #metrics == 0 then
        return true
    end
    
    local sock = ngx.socket.tcp()
    sock:settimeout(VM_TIMEOUT)
    
    -- 首先尝试容器名称，失败后尝试IP
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
        sock:close()
        return false
    end
    
    local body = table.concat(metrics, "\n")
    local request = table.concat({
        "POST " .. VM_PATH .. " HTTP/1.1",
        "Host: " .. VM_HOST .. ":" .. VM_PORT,
        "Content-Type: text/plain",
        "Content-Length: " .. #body,
        "Connection: close",
        "",
        body
    }, "\r\n")
    
    local bytes, err = sock:send(request)
    if not bytes then
        ngx.log(ngx.ERR, "发送指标到VictoriaMetrics失败: ", err)
        sock:close()
        return false
    end
    
    -- 读取响应状态行
    local line, err = sock:receive()
    if not line then
        ngx.log(ngx.ERR, "读取VictoriaMetrics响应失败: ", err)
        sock:close()
        return false
    end
    
    sock:close()
    
    -- 检查HTTP状态码
    local status_code = line:match("HTTP/%d+%.%d+ (%d+)")
    if status_code == "204" or status_code == "200" then
        ngx.log(ngx.DEBUG, "成功发送 ", #metrics, " 个指标到VictoriaMetrics")
        return true
    else
        ngx.log(ngx.ERR, "VictoriaMetrics返回错误状态: ", line)
        return false
    end
end

-- 异步发送指标（使用timer）
local function async_send_metrics(premature, metrics)
    if premature then
        return
    end
    
    local ok, err = pcall(send_metrics_cosocket, metrics)
    if not ok then
        ngx.log(ngx.ERR, "异步发送指标失败: ", err)
    end
end

-- 发送指标到 VictoriaMetrics
local function send_metrics(metrics)
    if not metrics or #metrics == 0 then
        return true
    end
    
    -- 使用timer异步发送，避免阻塞请求
    local ok, err = ngx.timer.at(0, async_send_metrics, metrics)
    if not ok then
        ngx.log(ngx.ERR, "创建异步timer失败: ", err)
        return false
    end
    
    return true
end

-- 记录请求指标
function _M.record_request(request_data)
    local timestamp = get_timestamp_ms()
    local metrics = {}
    
    -- 基本标签
    local base_labels = {
        channel = request_data.channel_name or "unknown",
        user_name = request_data.user_name or "unknown",  -- 使用用户名而不是key前8位
        model = request_data.model_name or "unknown",
        protocol = request_data.is_websocket and "websocket" or "http",
        status = request_data.status_category or "unknown"
    }
    
    -- 1. 请求计数器
    table.insert(metrics, build_metric("aiproxy_requests_total", base_labels, 1, timestamp))
    
    -- 2. 响应时间
    if request_data.response_time and request_data.response_time > 0 then
        local time_labels = {
            channel = base_labels.channel,
            model = base_labels.model,
            protocol = base_labels.protocol
        }
        table.insert(metrics, build_metric("aiproxy_response_time_seconds", time_labels, request_data.response_time, timestamp))
    end
    
    -- 3. 请求大小
    if request_data.request_size and request_data.request_size > 0 then
        local size_labels = {
            channel = base_labels.channel,
            user_name = base_labels.user_name
        }
        table.insert(metrics, build_metric("aiproxy_request_size_bytes", size_labels, request_data.request_size, timestamp))
    end
    
    -- 4. 响应大小
    if request_data.response_size and request_data.response_size > 0 then
        local size_labels = {
            channel = base_labels.channel,
            user_name = base_labels.user_name
        }
        table.insert(metrics, build_metric("aiproxy_response_size_bytes", size_labels, request_data.response_size, timestamp))
    end
    
    -- 5. WebSocket连接
    if request_data.is_websocket and request_data.status == 101 then
        local ws_labels = {
            channel = base_labels.channel
        }
        table.insert(metrics, build_metric("aiproxy_websocket_connections_total", ws_labels, 1, timestamp))
    end
    
    -- 发送指标
    return send_metrics(metrics)
end

-- 记录系统指标
function _M.record_system_metrics()
    local timestamp = get_timestamp_ms()
    local metrics = {}
    
    -- 系统运行时间
    local stats = ngx.shared.stats
    if stats then
        local start_time = stats:get("start_time") or ngx.time()
        local uptime = ngx.time() - start_time
        table.insert(metrics, build_metric("aiproxy_uptime_seconds", {}, uptime, timestamp))
        
        -- API密钥数量
        local api_keys_count = #(_G.api_keys or {})
        table.insert(metrics, build_metric("aiproxy_api_keys_total", {}, api_keys_count, timestamp))
    end
    
    -- 发送指标
    return send_metrics(metrics)
end

-- 批量发送指标（用于数据迁移）
function _M.send_batch_metrics(metrics_list)
    return send_metrics(metrics_list)
end

return _M