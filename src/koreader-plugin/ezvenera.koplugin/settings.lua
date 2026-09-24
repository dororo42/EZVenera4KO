--[[
EZVenera for KOReader — settings.lua
Persistent plugin settings with defaults. REQ: R1.3, R2.2.

KOReader-independent core: the storage backend is injectable so unit tests
can run under plain LuaJIT (scripts/run_tests.py). On device the backend is
KOReader's LuaSettings.
]]

local Settings = {}
Settings.__index = Settings

-- 审查 L5（2026-09-20 修订，用户确认）：默认代理地址不再预置内网 IP
-- （原值随仓分发布置会泄漏内网拓扑），改为空串 = 真机首配
-- （工具 → EZVenera 漫画 → 网络代理 → 编辑代理地址）。R2.2 已同步修订。
Settings.DEFAULT_PROXY_URL = ""
Settings.DEFAULT_TEST_URL = "http://www.msftconnecttest.com/connecttest.txt"
Settings.DEFAULT_SOURCE_INDEX_URL =
    "https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/index.json"

Settings.DEFAULTS = {
    proxy_enabled = false,
    proxy_url = Settings.DEFAULT_PROXY_URL,
    proxy_apply_global = false,
    proxy_test_url = Settings.DEFAULT_TEST_URL,
    source_index_url = Settings.DEFAULT_SOURCE_INDEX_URL,
}

--- settings_file / settings_key are declared on the module table so the
--- KOReader plugin manager offers "delete settings" for us.
Settings.settings_file = "ezvenera.lua"
Settings.settings_key = "ezvenera"

function Settings.new(backend)
    local o = setmetatable({}, Settings)
    o.backend = backend
    return o
end

--- Create the real on-device backend (KOReader LuaSettings).
--- Returns nil when not running inside KOReader.
function Settings.makeDeviceBackend()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage then return nil end
    local LuaSettings = require("luasettings")
    local path = DataStorage:getSettingsDir() .. "/ezvenera.lua"
    local store = LuaSettings:open(path)
    return {
        read = function(_, key, default)
            return store:readSetting(key, default)
        end,
        write = function(_, key, value)
            store:saveSetting(key, value)
        end,
        flush = function()
            store:flush()
        end,
    }
end

--- Table-backed backend for tests / non-KOReader environments.
function Settings.makeMemoryBackend()
    local data = {}
    return {
        read = function(_, key, default)
            local v = data[key]
            if v == nil then return default end
            return v
        end,
        write = function(_, key, value)
            data[key] = value
        end,
        -- R3-L5：内存后端无需序列化往返（flush no-op）
        flush = function() end,
        _data = data,
    }
end

--- Singleton with device backend when available, memory backend otherwise.
function Settings.open()
    if Settings._instance then return Settings._instance end
    local backend = Settings.makeDeviceBackend() or Settings.makeMemoryBackend()
    Settings._instance = Settings.new(backend)
    return Settings._instance
end

function Settings:get(key)
    local default = self.DEFAULTS[key]
    if default == nil then
        default = false
    end
    local v = self.backend:read(key, default)
    if v == nil then return default end
    return v
end

function Settings:set(key, value)
    self.backend:write(key, value)
    self.backend:flush()
end

function Settings:isProxyEnabled() return self:get("proxy_enabled") == true end
function Settings:getProxyURL() return self:get("proxy_url") end
function Settings:getProxyTestURL() return self:get("proxy_test_url") end
function Settings:isApplyGlobal() return self:get("proxy_apply_global") == true end

return Settings
