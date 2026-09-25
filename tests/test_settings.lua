-- unit test: settings.lua
local Settings = require("settings")
local stubs = require("tests.stubs")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
end

local tests = {}

function tests.default_proxy_url()
    local s = stubs.settings_memory()
    -- 审查 L5（R2.2 已同步修订）：默认代理地址为空 = 真机首配，
    -- 不再预置内网 IP（防仓库公开泄漏内网拓扑）
    assert_eq("default proxy_url empty", "", s:getProxyURL())
    return true
end

function tests.default_proxy_disabled()
    local s = stubs.settings_memory()
    assert_eq("proxy disabled default", false, s:isProxyEnabled())
    return true
end

function tests.set_and_read()
    local s = stubs.settings_memory()
    s:set("proxy_enabled", true)
    assert_eq("after set", true, s:isProxyEnabled())
    s:set("proxy_url", "http://10.0.0.1:3128")
    assert_eq("new url", "http://10.0.0.1:3128", s:getProxyURL())
    return true
end

function tests.default_test_url()
    local s = stubs.settings_memory()
    local u = s:getProxyTestURL()
    assert_eq("default test url non_empty", true, type(u) == "string" and #u > 0)
    return true
end

function tests.apply_global_default_false()
    local s = stubs.settings_memory()
    assert_eq("apply_global default", false, s:isApplyGlobal())
    return true
end

return tests