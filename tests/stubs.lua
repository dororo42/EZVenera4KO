-- 测试桩：LUASETTINGS_BACKEND
-- 注入到 settings.lua 模块的工具

local stubs = {}

-- 为测试提供一个纯净的 settings 后端（内存表 + 不访问 KOReader）
function stubs.settings_memory()
    local Settings = require("settings")
    local backend = Settings.makeMemoryBackend()
    return Settings.new(backend)
end

-- 伪造 netclient，可编程返回或断言
function stubs.fake_netclient(response_map)
    response_map = response_map or {}
    return {
        request = function(self, opts)
            local key = (opts.method or "GET") .. " " .. tostring(opts.url)
            local resp = response_map[key]
            if resp then return resp end
            return { status = 200, headers = {}, body = "ok", error = nil }
        end,
    }
end

-- 伪造 convert backend（注入 convert.new 用于 crypto 测试）
function stubs.fake_convert_impl(aes_fn, digest_fn, hmac_fn, gbk_fn)
    return {
        name = "fake",
        aes = aes_fn or function(mode, isEnc, data, key, iv, bs)
            return "aes(" .. mode .. (isEnc and ",enc" or ",dec") .. "):" .. data
        end,
        digest = digest_fn or function(name, data)
            return "digest(" .. name .. "):" .. data
        end,
        hmac = hmac_fn or function(name, key, data)
            return "hmac(" .. name .. "):" .. key .. ":" .. data
        end,
        encodeGbk = gbk_fn,
        decodeGbk = gbk_fn,
    }
end

-- 伪造 cookies 存储（+ json）
function stubs.fake_cookies()
    local Cookies = require("runtime.cookies")
    local jar = {}
    local fakeJson = {
        encode = function(v) return "{}" end,
        decode = function(s) return {} end,
    }
    local data = "{}"
    local storage = {
        load = function() return data end,
        save = function(d) data = d end,
    }
    return Cookies.new({ json = fakeJson, store = storage }),
        { get_data = function() return data end }
end

return stubs