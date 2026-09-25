-- unit test: proxyconf.lua — 校验 + 菜单无 hold 依赖（AC5.2）
local ProxyConf = require("proxyconf")
local stubs = require("tests.stubs")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local tests = {}

-- ---- validate ----

function tests.validate_http_ip()
    -- 203.0.113.x = RFC 5737 文档地址（审查 L5：不用真实内网 IP 做测试数据）
    local ok, err, parts = ProxyConf.validate("http://203.0.113.10:16492")
    assert_eq("ok", true, ok)
    assert_eq("scheme", "http", parts.scheme)
    assert_eq("host", "203.0.113.10", parts.host)
    assert_eq("port", 16492, parts.port)
    return true
end

function tests.validate_ipv6_literal()
    -- 审查 L4：IPv6 字面量（对齐 netclient.parseURL 行为）
    local ok, err, parts = ProxyConf.validate("http://[::1]:8080")
    assert_eq("ok", true, ok)
    assert_eq("host", "::1", parts.host)
    assert_eq("port", 8080, parts.port)
    local ok6 = ProxyConf.validate("http://[2001:db8::1]")
    assert_eq("ipv6 no port ok", true, ok6)
    return true
end

function tests.validate_https_domain()
    local ok, err, parts = ProxyConf.validate("https://proxy.example.com:8080")
    assert_eq("ok", true, ok)
    assert_eq("port", 8080, parts.port)
    return true
end

function tests.validate_no_port_default()
    local ok, err, parts = ProxyConf.validate("https://example.com")
    assert_eq("ok", true, ok)
    assert_eq("default port 443", 443, parts.port)
    return true
end

function tests.reject_empty()
    local ok, err = ProxyConf.validate("")
    assert_eq("reject empty", false, ok)
    return true
end

function tests.reject_no_scheme()
    local ok, err = ProxyConf.validate("203.0.113.10:16492")
    assert_eq("reject no scheme", false, ok)
    return true
end

function tests.reject_bad_scheme()
    local ok, err = ProxyConf.validate("ftp://host:21")
    assert_eq("reject ftp", false, ok)
    return true
end

function tests.reject_missing_host()
    local ok, err = ProxyConf.validate("http://:8080")
    assert_eq("reject missing host", false, ok)
    return true
end

function tests.reject_bad_port()
    local ok, err = ProxyConf.validate("http://host:99999")
    assert_eq("reject bad port", false, ok)
    return true
end

-- ---- effectiveURL ----

function tests.effective_url_disabled()
    local s = stubs.settings_memory()
    local u = ProxyConf.effectiveURL(s)
    assert_eq("effective disabled", nil, u)
    return true
end

function tests.effective_url_enabled()
    local s = stubs.settings_memory()
    s:set("proxy_enabled", true)
    local u = ProxyConf.effectiveURL(s)
    assert_eq("effective enabled", s:getProxyURL(), u)
    return true
end

-- ---- menu structure（AC5.2 无 hold 断言）----

local function collectItems(items)
    local flat = {}
    local function walk(t)
        for _, item in ipairs(t) do
            table.insert(flat, item)
            if item.sub_item_table then
                walk(item.sub_item_table)
            end
        end
    end
    walk(items)
    return flat
end

function tests.menu_has_no_hold_dependency()
    local s = stubs.settings_memory()
    local fake_ui = {
        infoMessage = function(t) end,
        scheduleIn = function(s, f) f() end,
        netclient = stubs.fake_netclient(),
    }
    local items = ProxyConf.buildMenu(s, fake_ui)
    local flat = collectItems(items)
    local found = {}
    for _, item in ipairs(flat) do
        if item.hold_callback ~= nil or item.hold_callback_func ~= nil
            or item.hold_input ~= nil then
            table.insert(found, item.text or item.text_func
                and item.text_func() or "?")
        end
    end
    assert_eq("hold violations", 0, #found)
    return true
end

function tests.menu_uses_plain_callbacks()
    local s = stubs.settings_memory()
    local fake_ui = {
        infoMessage = function(t) end,
        scheduleIn = function(s, f) f() end,
        netclient = stubs.fake_netclient(),
    }
    local items = ProxyConf.buildMenu(s, fake_ui)
    local flat = collectItems(items)
    -- 至少 5 项
    assert_eq("at least 5 items", true, #flat >= 5)
    -- 每项都有 callback 或 sub_item_table (proxy-many? only top sub items
    -- have it actually; fine as long as no hold_depend)
    for _, item in ipairs(flat) do
        if item.sub_item_table == nil then
            assert_eq(item.text_func and item.text_func() or item.text or "?",
                true, type(item.callback) == "function"
                    or item.callback_func ~= nil)
        end
    end
    return true
end

-- ---- remoteinput 弱依赖 ----
-- 2026-09-22：扫码远程输入功能已按用户决策整体移除，弱依赖用例随之删除。

function tests.reset_default_url_while_enabled_disables_proxy()
    -- 审查 L2（独立报告）：默认地址为空时"恢复默认地址"必须同时禁用
    -- 代理，避免 UI 显示已启用、实际直连的状态错位
    local s = stubs.settings_memory()
    s:set("proxy_enabled", true)
    s:set("proxy_url", "http://203.0.113.10:16492")
    local fake_ui = {
        infoMessage = function() end,
        scheduleIn = function(_, f) f() end,
        netclient = stubs.fake_netclient(),
    }
    local items = ProxyConf.buildMenu(s, fake_ui)
    local reset
    for _, item in ipairs(items) do
        if item.text == "恢复默认地址" then reset = item.callback end
    end
    assert(reset ~= nil, "reset item exists")
    reset()
    assert_eq("proxy disabled", false, s:isProxyEnabled())
    assert_eq("url reset to default", "", s:getProxyURL())
    return true
end

function tests.reset_default_url_when_disabled_keeps_disabled()
    -- 未启用时恢复默认：只重置地址，不动启用状态
    local s = stubs.settings_memory()
    s:set("proxy_enabled", false)
    s:set("proxy_url", "http://203.0.113.10:16492")
    local fake_ui = {
        infoMessage = function() end,
        scheduleIn = function(_, f) f() end,
        netclient = stubs.fake_netclient(),
    }
    local items = ProxyConf.buildMenu(s, fake_ui)
    for _, item in ipairs(items) do
        if item.text == "恢复默认地址" then item.callback() end
    end
    assert_eq("still disabled", false, s:isProxyEnabled())
    assert_eq("url reset", "", s:getProxyURL())
    return true
end

return tests