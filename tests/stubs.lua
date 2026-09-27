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

-- jshost 在【模块加载期】捕获 logger，所以想验日志就必须让桩先于 require。
-- 多个测试文件都要抓日志时，共享这一个入口：每次都装新桩并强制重载 jshost，
-- 否则「谁先 require 谁赢」会把后写的文件变成假通过。
function stubs.reload_jshost_with_logger()
    local sink = { warns = {}, dbgs = {}, infos = {} }
    local function rec(t)
        return function(msg, ...)
            local line = tostring(msg)
            for i = 1, select("#", ...) do
                line = line .. " " .. tostring((select(i, ...)))
            end
            table.insert(t, line)
        end
    end
    local noop = function() end
    package.preload["logger"] = function() return {
        warn = rec(sink.warns), dbg = rec(sink.dbgs), info = rec(sink.infos),
        err = noop, verbose = noop, setLevel = noop,
    } end
    package.loaded["logger"] = package.preload["logger"]()
    package.loaded["runtime.jshost"] = nil
    local JsHost = require("runtime.jshost")
    --- 就地清空（recorder 捕获的是表本身，换新表会把写入留在旧表里）
    function sink.reset()
        for i = #sink.warns, 1, -1 do sink.warns[i] = nil end
        for i = #sink.dbgs, 1, -1 do sink.dbgs[i] = nil end
        for i = #sink.infos, 1, -1 do sink.infos[i] = nil end
    end
    return JsHost, sink
end

return stubs