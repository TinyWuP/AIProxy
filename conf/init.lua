-- OpenResty初始化模块
-- 加载配置和初始化统计数据

local cjson = require "cjson"

-- 获取配置文件的绝对路径和相对路径
local function get_config_path(relative_path)
    local base_dir = ngx.config.prefix()
    local full_path = base_dir .. relative_path
    return full_path, relative_path
end

-- 尝试打开配置文件
-- 先尝试使用绝对路径，如果失败再使用相对路径
local function open_config_file(relative_path)
    local full_path, rel_path = get_config_path(relative_path)
    
    -- 记录日志
    ngx.log(ngx.INFO, "尝试打开配置文件: " .. full_path)
    
    -- 尝试使用完整路径打开文件
    local file = io.open(full_path, "r")
    if not file then
        -- 尝试使用相对路径
        file = io.open(rel_path, "r")
        if not file then
            ngx.log(ngx.ERR, "无法打开配置文件: " .. full_path)
            return nil
        else
            ngx.log(ngx.INFO, "使用相对路径成功打开: " .. rel_path)
        end
    else
        ngx.log(ngx.INFO, "使用绝对路径成功打开: " .. full_path)
    end
    
    return file
end

-- 初始化统计数据
local stats = ngx.shared.stats
if not stats:get("total_requests") then
    stats:set("total_requests", 0)
    stats:set("successful_requests", 0)
    stats:set("failed_requests", 0)
    stats:set("start_time", ngx.time())
end

-- 加载API Key配置
local function load_api_keys()
    local file = open_config_file("conf/api_keys.json")
    if not file then
        return {}
    end
    
    local content = file:read("*all")
    file:close()
    
    local ok, keys = pcall(cjson.decode, content)
    if not ok then
        ngx.log(ngx.ERR, "API Key配置文件格式错误")
        return {}
    end
    
    return keys
end

-- 全局变量
_G.api_keys = load_api_keys()
-- 导出路径处理函数供其他模块使用
_G.open_config_file = open_config_file

ngx.log(ngx.INFO, "OpenResty初始化完成，加载了 " .. #_G.api_keys .. " 个API Key") 