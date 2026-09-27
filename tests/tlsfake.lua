-- 共享的「假 luasocket / LuaSec 栈」。
-- 为什么从 test_netclient.lua 抽出来：r10 M2 之后，端到端验证要从**真的**
-- NetClient（含 AsyncNet 非阻塞传输）一路串到**真的** Bridge 与 JsHost:pump()，
-- 两处各写一份假栈必然漂移，所以栈只留一份。
-- 本地 LuaJIT 里根本没有 luasocket/luasec（M0 在真机测出：真机有 3.1.0/1.3.2），
-- 所以这个桩就是本地唯一能提供「一拍只推进一件事」这个真机属性的东西。
--
-- 形状约束（照真机抄，不得松）：
--   · conn 的方法挂在 metatable.__index 上（netclient 的 _tlsConn 按这个取）
--   · socket.select 只吃带 getfd 的对象，非阻塞轮询 timeout 恒 0
--   · 「动作要等」与「select 说就绪」必须是两拍的事（否则等待根本不存在）
--   · LuaSec 握手返回 false,"wantread"，同步成功返回 1

local TlsFake = {}

function TlsFake.makeFakeHttp(opts)
    opts = opts or {}
    local fake
    fake = {
        TIMEOUT = 10,
        PROXY = opts.global_proxy,          -- 模拟 NetworkMgr:setHTTPProxy 写入
        _calls = {},
        responses = nil,                    -- {code, headers, body} 队列（TLS 桩用）
        request = function(reqt)
            fake._calls[#fake._calls + 1] = {
                reqt = reqt,
                proxy_during = reqt.proxy,
                global_during = fake.PROXY, -- 请求执行时看到的全局值
            }
            if opts.fail then return nil, "timeout" end
            -- 自建 HTTPS 路径会传 create：按 luasocket 的 _M.open 形状走一遍
            if reqt.create then return fake.open_with(reqt) end
            return 1, 200, { ["content-type"] = "text/plain" },
                "HTTP/1.1 200 OK"
        end,
    }
    return fake
end

-- ltn12 的 sink/source 在真库里是**函数**（sink 吃 source、吐块）。桩如果返回
-- 一个表，桩就永远喂不出 body，「响应字节一路到 JS」这条链在本地无从断言。
TlsFake.ltn12 = {
    sink = {
        table = function(t)
            return function(src)
                while true do
                    local chunk, err = src()
                    if not chunk then
                        if err then return nil, err end
                        break
                    end
                    t[#t + 1] = chunk
                end
                return #t
            end
        end,
    },
    source = {
        string = function(s)
            local left = s
            return function()
                if not left then return nil end
                local out = left
                left = nil
                return out
            end
        end,
    },
}
local fake_ltn12 = TlsFake.ltn12

--- 在桩模块下执行 fn；结束恢复 preload/package.loaded 现场
function TlsFake.withFakeModules(mods, fn)
    local saved_preload, saved_loaded = {}, {}
    for name, _ in pairs(mods) do
        saved_preload[name] = package.preload[name]
        saved_loaded[name] = package.loaded[name]
    end
    for name, mod in pairs(mods) do
        package.preload[name] = function() return mod end
        package.loaded[name] = nil
    end
    local ok, err = pcall(fn)
    for name, _ in pairs(mods) do
        package.preload[name] = saved_preload[name]
        if saved_loaded[name] ~= nil then
            package.loaded[name] = saved_loaded[name]
        else
            package.loaded[name] = nil
        end
    end
    if not ok then error(err) end
end

--- log 中首个匹配行（Lua 模式），无则 nil
function TlsFake.logFind(log, pat)
    for i, line in ipairs(log) do
        if line:find(pat) then return i end
    end
    return nil
end

--- 日志中匹配 Lua 模式 `pat` 的行数
function TlsFake.countLog(log, pat)
    local n = 0
    for _, line in ipairs(log) do
        if line:find(pat) then n = n + 1 end
    end
    return n
end

--- 两个端到端文件共用的响应体：源会看到的 JSON，里面同时有引号、反斜杠、
--- **裸换行**和 UTF-8。这四个都是 jsLiteral 的靶子——漏转义任何一个，那条
--- eval 就变 SyntaxError，表现为「Promise 永挂、界面毫无解释地等」。
TlsFake.BODY = '{"title":"你好","q":"a\\"b","raw":"x\ny"}'

-- 极简 JSON（真机上是 cjson/rapidjson）：只覆盖端到端用例的形状，
-- 关键是**字符串转义规则与 cjson 一致**（反斜杠先加倍，再处理引号与换行）。
function TlsFake.jsonEnc(v)
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub("\\", "\\\\"):gsub('"', '\\"')
            :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        if #v > 0 then
            local s = {}
            for _, x in ipairs(v) do s[#s + 1] = TlsFake.jsonEnc(x) end
            return "[" .. table.concat(s, ",") .. "]"
        end
        local s = {}
        for k, x in pairs(v) do
            if x ~= nil then
                s[#s + 1] = TlsFake.jsonEnc(k) .. ":" .. TlsFake.jsonEnc(x)
            end
        end
        table.sort(s)
        return "{" .. table.concat(s, ",") .. "}"
    end
    assert(t == "nil", "jsonEnc 不支持的类型: " .. t)
    return "null"
end

--- 反解 JS 字符串字面量（只认 \" \\ \n \r \t \uXXXX）——模拟 JS 引擎把那层
--- 引号里的内容还原成字符串。未知转义直接报错：静默放过等于把「拼坏了字面量」
--- 伪装成「结果还没到」。
local ESC = { n = "\n", r = "\r", t = "\t", ["\\"] = "\\", ['"'] = '"' }
function TlsFake.jsUnescape(s)
    local out, i = {}, 1
    while i <= #s do
        local c = s:sub(i, i)
        if c ~= "\\" then
            out[#out + 1] = c
            i = i + 1
        else
            local n = s:sub(i + 1, i + 1)
            if n == "u" then
                local b = tonumber(s:sub(i + 2, i + 5), 16)
                assert(b ~= nil and b < 256, "非法的 \\u 转义")
                out[#out + 1] = string.char(b)
                i = i + 6
            else
                assert(ESC[n] ~= nil, "非法的转义序列: \\" .. tostring(n))
                out[#out + 1] = ESC[n]
                i = i + 2
            end
        end
    end
    return table.concat(out)
end

--- 桩化 LuaJIT 环境下不存在的 socket / LuaSec / socket.url / socket.http，
--- 结果写进 `fake.mods`（调用方交给 withFakeModules）。
--- 内部：让 fake http.request 按 luasocket `_M.open` 的真实动作顺序驱动
--- conn（create → settimeout → connect(代理|目标) → send 请求行 → 喂 sink），
--- 从而能断言 CONNECT 隧道 + TLS 包装 + origin-form 请求行。返回动作流水。
--- blocked = { connect = n, handshake = n, receive = n }：让前 n 次该动作
--- 返回「现在没数据」，用来驱动 r10 M1 的非阻塞路径——异步作业必须 yield
--- 回节拍而不是原地等。
function TlsFake.withTlsStack(fake, tls_opts)
    tls_opts = tls_opts or {}
    local log = {}
    local reply = tls_opts.reply
        or { "HTTP/1.1 200 Connection established", "" }
    fake.responses = tls_opts.responses or {}
    local blocked = tls_opts.blocked or {}
    local env = { log = log, t = 100, polls = 0, not_ready = 0,
                  poll_timeout = nil, warmed = true }

    local function takeBlocked(op)
        local n = blocked[op]
        if not n or n <= 0 then return false end
        blocked[op] = n - 1
        -- 「动作要等」与「轮询说好了」必须是两拍的事：真机上 select 报可读
        -- 之前一定先报过一次没可读，否则等待根本不存在，测试也就测不到
        env.warmed = false
        return true
    end

    local function newsock(kind)
        local api, rx = {}, 0
        api.connect = function(self, host, port)
            log[#log + 1] = kind .. ".connect " .. host .. ":" .. tostring(port)
            if tls_opts.connect_fails then return nil, "connection refused" end
            if takeBlocked("connect") then
                log[#log + 1] = kind .. ".connect would-block"
                return nil, "timeout"
            end
            return 1
        end
        api.send = function(self, data)
            log[#log + 1] = kind .. ".send " .. data
            return #data
        end
        -- 按 luasocket/LuaSec 的 receive 形状实现：`receive(n)` 只吃字节、
        -- 行内剩余留给下一次，`receive(pattern, prefix)` 把前缀接回结果。
        -- luasocket 的 receivestatusline 正是「receive(5) → receive("*l",
        -- "HTTP/")」两步，桩若吞掉第二个入参就复刻不出真机行为（r10 M1 的
        -- 真机回归就漏在这里）。
        local have, pending = false, nil
        api.receive = function(self, pat, prefix)
            if takeBlocked("receive") then
                -- 「现在没数据」不消费应答行：真机上重试读到的是同一行
                log[#log + 1] = kind .. ".receive would-block"
                return nil, "timeout"
            end
            if not have then
                rx = rx + 1
                pending, have = reply[rx], true
            end
            local v
            if type(pat) == "number" then
                v = (pending or ""):sub(1, pat)
                pending = (pending or ""):sub(pat + 1)
                if pending == "" then have = false end
            else
                v, pending, have = pending, nil, false
            end
            if prefix ~= nil then v = prefix .. (v or "") end
            log[#log + 1] = kind .. ".receive " .. tostring(v)
            return v
        end
        api.settimeout = function(self, t)
            log[#log + 1] = kind .. ".settimeout " .. tostring(t)
            return 1
        end
        api.sni = function(self, h)
            log[#log + 1] = kind .. ".sni " .. h
            return 1
        end
        api.dohandshake = function(self)
            log[#log + 1] = kind .. ".dohandshake"
            if takeBlocked("handshake") then
                log[#log + 1] = "tls.dohandshake wantread"
                return false, "wantread"
            end
            return 1
        end
        api.want = function(self, dir)
            log[#log + 1] = kind .. ".want " .. tostring(dir)
            return "read"
        end
        api.getfd = function(self) return 7 end
        api.dirty = function(self) return false end
        api.close = function(self)
            log[#log + 1] = kind .. ".close"
            return 1
        end
        -- luasocket/LuaSec 都是 metatable.__index 挂方法：conn 侧要按
        -- getmetatable(x).__index 取，故桩对象必须同形
        return setmetatable({}, { __index = api })
    end

    fake.open_with = function(reqt)
        local conn = reqt.create()
        if not conn then return nil, "create failed" end
        conn:settimeout(fake.TIMEOUT)
        local host = reqt.url:match("^%a[%w+.-]*://([^/:]+)")
        local tport = tonumber(reqt.url:match("^%a[%w+.-]*://[^/:]+:(%d+)")) or 443
        local p = reqt.proxy or fake.PROXY
        if p then
            host = p:match("^%a[%w+.-]*://([^/:]+)") or host
            tport = tonumber(p:match(":(%d+)$")) or 3128
        end
        local ok, err = conn:connect(host, tport)
        if not ok then return nil, err end
        conn:send((reqt.method or "GET") .. " " .. (reqt.uri or "/")
            .. " HTTP/1.1\r\n")
        local r = table.remove(fake.responses, 1) or { code = 200, headers = {} }
        if reqt.sink and r.body then
            -- luasocket 在 _M.open 里把响应体喂给 sink；不喂就等于 body 恒空，
            -- M2 之后的「字节一路送到 JS」在本地就无从验证
            reqt.sink(fake_ltn12.source.string(r.body))
        end
        conn:close()
        return 1, r.code, r.headers, "HTTP/1.1 " .. tostring(r.code)
    end

    fake.mods = {
        ["socket.http"] = fake,
        ["socket"] = {
            tcp = function() return newsock("tcp") end,
            -- 真机 socket.select 只吃带 getfd 的对象（M0 实测），且非阻塞
            -- 轮询的 timeout 恒为 0；两者都在这里一起断言
            select = function(rs, ws, t)
                env.polls = env.polls + 1
                env.poll_timeout = t
                log[#log + 1] = "select"
                if not env.warmed then
                    env.warmed = true
                    env.not_ready = env.not_ready + 1
                    log[#log + 1] = "select not-ready"
                    return {}, {}, nil
                end
                return rs or {}, ws or {}, nil
            end,
            gettime = function() return env.t end,
        },
        ["ssl"] = {
            wrap = function(sock, params)
                log[#log + 1] = "ssl.wrap mode=" .. tostring(params.mode)
                    .. " verify=" .. tostring(params.verify)
                    .. " protocol=" .. tostring(params.protocol)
                return newsock("tls")
            end,
        },
        ["socket.url"] = {
            absolute = function(base, loc)
                if loc:match("^%a[%w+.-]*://") then return loc end
                local root = base:match("^%a[%w+.-]*://[^/]*")
                if loc:match("^/") then return root .. loc end
                return root .. "/" .. loc
            end,
        },
        ltn12 = fake_ltn12,
    }
    return log, env
end

--- 把在飞作业推进到结束（或拍数用尽）；返回实际拍数
function TlsFake.drain(nc, env, max_ticks)
    for i = 1, max_ticks or 30 do
        env.t = env.t + 0.05
        nc:tickAsync()
        if env.done then return i end
    end
    return nil
end

return TlsFake
