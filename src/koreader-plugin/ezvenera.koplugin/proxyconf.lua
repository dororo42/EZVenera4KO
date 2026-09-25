--[[
EZVenera for KOReader — proxyconf.lua
代理配置：校验 / 应用 / 测试。REQ: R2.1-R2.6, R5.1（无长按红线，ADR-003/005）。

设计要点：
- 所有菜单入口均为普通菜单项（callback），不使用 hold_input / hold_callback。
- 插件层代理由 netclient 在每次请求时按配置注入（http 传 proxy=，https 走 CONNECT）。
- "应用到 KOReader 全局"为可选开关，写 socket.http.PROXY（NetworkMgr:setHTTPProxy）。
  已知局限（研究报告 02 §4）：原生全局代理不影响 ssl.https/turbo/httpasync，
  因此插件自身流量永不依赖全局开关。
]]

local ProxyConf = {}
ProxyConf.__index = ProxyConf

local function loggerWarn(msg)
    local ok, logger = pcall(require, "logger")
    if ok and logger then logger.warn("[ezvenera] ", msg) end
end

--- 校验代理 URL：scheme://host:port（可带路径）。返回 ok, errMessage, parts。
--- 纯 Lua 实现（不依赖 socket.url），便于单测与离线校验。
function ProxyConf.validate(url)
    if type(url) ~= "string" or #url == 0 then
        return false, "代理地址不能为空"
    end
    local scheme, rest = url:match("^(%a[%w+.-]*)://(.+)$")
    if not scheme then
        return false, "缺少 scheme://（例如 http://192.168.1.100:8118）"
    end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then
        return false, "scheme 仅支持 http/https，收到: " .. scheme
    end
    local authority = rest:match("^([^/?#]+)")
    if not authority or #authority == 0 then
        return false, "缺少 host:port"
    end
    local userinfo, hostport = authority:match("^([^@]*)@(.+)$")
    if userinfo and #userinfo == 0 then
        return false, "userinfo 不能为空（可省略）"
    end
    if not hostport then
        hostport = authority   -- 无 userinfo 的情况
    end
    -- 审查 L4：IPv6 字面量 [::1]:8080（对齐 netclient.parseURL 行为）
    local host, port
    if hostport:sub(1, 1) == "[" then
        host, port = hostport:match("^%[([^%]]+)%]:(%d+)$")
        if not host then
            host = hostport:match("^%[([^%]]+)%]$")
            port = scheme == "https" and "443" or "80"
        end
    else
        host, port = hostport:match("^([^:]+):(%d+)$")
        if not host then
            -- 允许无端口：http 默认 80，https 默认 443
            host = hostport:match("^([^:]+)$")
            port = scheme == "https" and "443" or "80"
        end
    end
    if not host or #host == 0 then
        return false, "host 不能为空"
    end
    port = tonumber(port)
    if not port or port < 1 or port > 65535 then
        return false, "端口必须是 1-65535 的数字"
    end
    return true, nil, { scheme = scheme, host = host, port = port,
                        userinfo = userinfo }
end

--- 返回插件层生效的代理 URL；未启用返回 nil。
function ProxyConf.effectiveURL(settings)
    if not settings:isProxyEnabled() then return nil end
    return settings:getProxyURL()
end

--- 可选：把代理同步给 KOReader 全局（仅 socket.http 生效，UI 文案已说明局限）。
function ProxyConf.applyGlobal(settings)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr then
        loggerWarn("NetworkMgr unavailable, global proxy not applied")
        return false
    end
    if settings:isApplyGlobal() and settings:isProxyEnabled() then
        -- L8（审查报告 §4）：首次接管全局前记住用户原生配置，
        -- 关闭同步时还原而不是无脑清空（clobber 修复）
        if settings.backend:read("proxy_global_prev_url", nil) == nil then
            local G = rawget(_G, "G_reader_settings")
            local prev = nil
            if G and type(G.readSetting) == "function" then
                prev = G:readSetting("http_proxy")
            end
            settings.backend:write("proxy_global_prev_url", prev or false)
        end
        NetworkMgr:setHTTPProxy(settings:getProxyURL())
    else
        local prev = settings.backend:read("proxy_global_prev_url", nil)
        if prev == nil then
            -- 从未由插件接管过：不动全局（旧实现此处会 clobber）
            return true
        end
        if prev == false then
            NetworkMgr:setHTTPProxy(nil)      -- 原本就没有全局代理
        else
            NetworkMgr:setHTTPProxy(prev)     -- 还原用户原生代理
        end
        settings.backend:write("proxy_global_prev_url", nil)
    end
    return true
end

--- 经代理发探测请求。阻塞（短超时），返回 ok, status, elapsed_ms, err。
--- 独立成函数便于菜单回调在 scheduleIn 中调用。
--- 计时用 socket.gettime()（墙钟；os.clock 是 CPU 时间，网络等待会失真）。
function ProxyConf.testProxy(netclient, proxy_url, test_url)
    local socketok, socket = pcall(require, "socket")
    local start
    if socketok and socket and socket.gettime then
        start = socket.gettime()
    else
        start = os.time()
    end
    local resp = netclient:request({
        url = test_url,
        method = "GET",
        proxy = proxy_url,
        timeout_block = 5,
        timeout_total = 15,
    })
    local elapsed
    if socketok and socket and socket.gettime then
        elapsed = math.floor((socket.gettime() - start) * 1000)
    else
        elapsed = math.floor((os.time() - start) * 1000)
    end
    if resp.error then
        return false, nil, elapsed, resp.error
    end
    return true, resp.status, elapsed, nil
end

--- 构建代理子菜单（全部普通菜单项，无任何 hold 依赖）。ADR-005。
--- ui 注入：infoMessage(text)、scheduleIn(sec, fn)、netclient；
--- 缺省时（KOReader 外）退化为直接执行。
function ProxyConf.buildMenu(settings, ui)
    ui = ui or {}
    local function info(text)
        if ui.infoMessage then
            ui.infoMessage(text)
        end
    end
    local function showInputDialog()
        local okDlg, InputDialog = pcall(require, "ui/widget/inputdialog")
        local okUI, UIManager = pcall(require, "ui/uimanager")
        if not okDlg or not okUI then
            info("当前地址: " .. settings:getProxyURL()
                .. "\n（对话框仅在 KOReader 内可用）")
            return
        end
        local dialog
        dialog = InputDialog:new{
            title = "代理地址（scheme://host:port）",
            input = settings:getProxyURL(),
            input_hint = "例如 http://192.168.1.100:8118",
            buttons = {
                {
                    {
                        text = "取消",
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                    {
                        text = "保存",
                        is_enter_default = true,
                        callback = function()
                            local value = dialog:getInputText()
                            if type(value) == "string" then
                                value = value:gsub("%s+$", "")
                            end
                            local okv, err = ProxyConf.validate(value)
                            if not okv then
                                info("保存失败: " .. tostring(err))
                                return
                            end
                            settings:set("proxy_url", value)
                            UIManager:close(dialog)
                            info("代理地址已保存: " .. value)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    local items = {
        {
            text_func = function()
                if settings:isProxyEnabled() then
                    return "禁用代理"
                end
                return "启用代理"
            end,
            callback = function()
                local newv = not settings:isProxyEnabled()
                if newv and (settings:getProxyURL() or "") == "" then
                    -- 审查 L5：默认地址为空（真机首配），禁止空地址启用
                    info("代理地址为空，请先用『编辑代理地址』配置")
                    return
                end
                settings:set("proxy_enabled", newv)
                ProxyConf.applyGlobal(settings)
                if newv then
                    info("代理已启用: " .. settings:getProxyURL())
                else
                    info("代理已禁用（插件请求直连）")
                end
            end,
            keep_menu_open = true,
        },
        {
            text = "编辑代理地址",
            callback = showInputDialog,
            keep_menu_open = true,
        },
        {
            text = "恢复默认地址",
            callback = function()
                settings:set("proxy_url", settings.DEFAULT_PROXY_URL)
                if (settings.DEFAULT_PROXY_URL or "") == "" then
                    -- 审查 L2（独立报告）：默认地址为空与"已启用"互斥——
                    -- 若当前启用中，只置空 URL 会出现 UI 显示已启用、
                    -- 实际直连的状态错位。对齐启用入口的守卫，一并禁用。
                    if settings:isProxyEnabled() then
                        settings:set("proxy_enabled", false)
                        ProxyConf.applyGlobal(settings)
                        info("默认地址为空，已同时禁用代理"
                            .. "（请先『编辑代理地址』再启用）")
                    else
                        info("默认地址为空（真机首配），请用『编辑代理地址』输入")
                    end
                else
                    info("已恢复默认: " .. settings.DEFAULT_PROXY_URL)
                end
            end,
            keep_menu_open = true,
        },
        {
            text = "查看当前配置",
            callback = function()
                local def = settings.DEFAULT_PROXY_URL
                if def == nil or def == "" then def = "(空，真机首配)" end
                info(string.format(
                    "启用: %s\n地址: %s\n全局同步: %s\n默认: %s",
                    tostring(settings:isProxyEnabled()),
                    settings:getProxyURL(),
                    tostring(settings:isApplyGlobal()),
                    def))
            end,
            keep_menu_open = true,
        },
        {
            text = "测试代理",
            callback = function()
                if not settings:isProxyEnabled() then
                    info("代理未启用，请先『启用代理』")
                    return
                end
                local function runTest()
                    local okv, status, ms, err = ProxyConf.testProxy(
                        ui.netclient, settings:getProxyURL(),
                        settings:getProxyTestURL())
                    if okv then
                        info(string.format("测试成功 ◆ HTTP %s (%d ms)",
                            tostring(status), ms))
                    else
                        info(string.format("测试失败 × (%d ms)\n%s",
                            ms, tostring(err)))
                    end
                end
                if ui.scheduleIn then
                    info("正在测试: " .. settings:getProxyURL() .. " …")
                    ui.scheduleIn(0.2, runTest)
                else
                    runTest()
                end
            end,
            keep_menu_open = true,
        },
        {
            text = "同时应用于 KOReader 全局",
            checked_func = function() return settings:isApplyGlobal() end,
            callback = function()
                local newv = not settings:isApplyGlobal()
                settings:set("proxy_apply_global", newv)
                ProxyConf.applyGlobal(settings)
                info(newv and "已同步全局（仅影响 socket.http）"
                    or "已取消全局同步")
            end,
            keep_menu_open = true,
            help_text = "KOReader 原生全局代理只对部分请求路径生效；"
                .. "本插件的流量始终走上面的插件级代理设置。",
        },
    }
    return items
end

return ProxyConf
