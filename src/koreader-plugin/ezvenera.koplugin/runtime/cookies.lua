--[[
EZVenera for KOReader — runtime/cookies.lua
Venera cookie jar 语义的 Lua 实现。REQ: R3.2（cookie handler 底座）。

契约对齐（研究报告 01 §2/§5）：
  - setCookies(url, list)：list 元素 {name, value, domain, path, expires(ms),
    secure, httpOnly}；domain 可带前导点（匹配自身+子域）
  - getCookies(url) → 数组（同一返回形状，供 JS 侧修改后回传——ehentai 跨域
    cookie 复制流依赖此形状）
  - deleteCookies(url)
  - headerFor(url) → "k=v; k2=v2"（域后缀 + 路径前缀匹配 + 过期清理）

持久化：JSON 文件（注入 json 编解码与读写函数，设备上走 KOReader 内建 json
模块与 io；单测注入桩）。
]]

local Cookies = {}
Cookies.__index = Cookies

function Cookies.new(deps)
    deps = deps or {}
    local o = setmetatable({}, Cookies)
    o.json = deps.json                          -- { encode = fn, decode = fn }
    o.store = deps.store                        -- { load = fn, save = fn(dataStr) }
    o.now = deps.now or function() return os.time() end
    o.jar = {}
    o:load()
    return o
end

function Cookies._defaultJson()
    local ok, json = pcall(require, "json")
    if ok and json and json.encode and json.decode then
        return { encode = function(v) return json.encode(v) end,
                 decode = function(s) return json.decode(s) end }
    end
    return nil
end

function Cookies._defaultStore(path)
    return {
        load = function()
            local f = io.open(path, "r")
            if not f then return nil end
            local data = f:read("*a")
            f:close()
            return data
        end,
        save = function(dataStr)
            local f = io.open(path, "w")
            if not f then return false end
            f:write(dataStr)
            f:close()
            return true
        end,
    }
end

function Cookies:path()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then
        return DataStorage:getDataDir() .. "/ezvenera/cookies.json"
    end
    return "ezvenera/cookies.json"
end

function Cookies:load()
    local json = self.json
    if not json then
        local j = Cookies._defaultJson()
        if not j then return end
        self.json = j
        json = j
    end
    if not self.store then
        self.store = Cookies._defaultStore(self:path())
    end
    local ok, data = pcall(function() return self.store.load() end)
    if not ok or not data then return end
    local okd, parsed = pcall(function() return json.decode(data) end)
    if okd and type(parsed) == "table" then
        self.jar = parsed
    end
end

function Cookies:save()
    if not self.json then return false end
    if not self.store then self.store = Cookies._defaultStore(self:path()) end
    local ok, s = pcall(function() return self.json.encode(self.jar) end)
    if not ok then return false end
    local oks = pcall(function() return self.store.save(s) end)
    return oks
end

-- host 提取（不含端口）；无法解析返回 nil
local function hostOf(url)
    if type(url) ~= "string" then return nil end
    local authority = url:match("^%a+://([^/?#]+)")
    if not authority then return nil end
    return (authority:gsub(":%d+$", ""))
end

local function domainMatches(host, domain)
    if not host or not domain then return false end
    local d = domain:gsub("^%.", "")
    local h = host:lower()
    d = d:lower()
    if h == d then return true end
    return h:sub(-#d - 1) == "." .. d
end

local function pathMatches(reqpath, cookiepath)
    if not cookiepath or cookiepath == "" then cookiepath = "/" end
    if reqpath == cookiepath then return true end
    if reqpath:sub(1, #cookiepath) == cookiepath then
        if cookiepath:sub(-1) == "/" then return true end
        if reqpath:sub(#cookiepath + 1, #cookiepath + 1) == "/" then
            return true
        end
    end
    return false
end

function Cookies:purge()
    local now = self.now() * 1000
    local changed = false
    for k, c in pairs(self.jar) do
        if c.expires and c.expires ~= -1 and c.expires < now then
            self.jar[k] = nil
            changed = true
        end
    end
    return changed
end

function Cookies:setCookies(url, list)
    if type(list) ~= "table" then return 0 end
    local host = hostOf(url) or ""
    local count = 0
    for _, c in ipairs(list) do
        if type(c) == "table" and c.name and c.value ~= nil then
            local domain = c.domain or host
            -- 与 EZVenera 一致：允许把 cookie 改写到其它域（ehentai 复制流）
            local path = c.path or "/"
            local key = table.concat(
                { c.name, (domain:gsub("^%.", ""):lower()), path }, "\t")
            self.jar[key] = {
                name = c.name, value = c.value, domain = domain, path = path,
                expires = c.expires or -1,
                secure = c.secure == true, httpOnly = c.httpOnly == true,
            }
            count = count + 1
        end
    end
    self:purge()
    self:save()
    return count
end

function Cookies:getCookies(url)
    self:purge()   -- 读取时同步清理过期项
    local host = hostOf(url) or ""
    local reqpath = url:match("%a+://[^/]+(/[^?#]*)") or "/"
    local out = {}
    for _, c in pairs(self.jar) do
        if domainMatches(host, c.domain) and pathMatches(reqpath, c.path)
            and not (c.secure and not url:match("^https:")) then
            table.insert(out, {
                name = c.name, value = c.value, domain = c.domain,
                path = c.path, expires = c.expires, secure = c.secure,
                httpOnly = c.httpOnly,
            })
        end
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

function Cookies:deleteCookies(url)
    local host = hostOf(url) or ""
    local removed = 0
    for k, c in pairs(self.jar) do
        if domainMatches(host, c.domain) then
            self.jar[k] = nil
            removed = removed + 1
        end
    end
    self:save()
    return removed
end

--- 请求头构造（供 netclient 调用方合并；与插件自带 cookie 头冲突时
--- 调用方决定优先级——Venera 语义为合并）
function Cookies:headerFor(url)
    local list = self:getCookies(url)
    if #list == 0 then return nil end
    local parts = {}
    for _, c in ipairs(list) do
        parts[#parts + 1] = c.name .. "=" .. c.value
    end
    return table.concat(parts, "; ")
end

--- 拆分被 luasocket 逗号合并的多条 Set-Cookie（审查 M2）。
--- luasocket http.receiveheaders 会把重复 Set-Cookie 头连接成一条
--- "k1=v1; Path=/, k2=v2; Domain=x"；朴素按逗号切会把 Expires 的
--- "Wed, 21 Oct" 断开，按「新段是否以 name= 起始」启发式合并回。
local function splitSetCookie(joined)
    if type(joined) ~= "string" then return { joined } end
    local out, buf = {}, ""
    for seg in joined:gmatch("[^,]+") do
        if buf == "" then
            buf = seg
        elseif seg:match("^%s*[^=;,]+=") then
            -- 新 cookie 的 name= 起点（name 段内不允许 , ; =）
            out[#out + 1] = buf
            buf = seg
        else
            -- Expires 的 "Wed, 21 Oct" 型逗号：并回当前段
            buf = buf .. "," .. seg
        end
    end
    if buf ~= "" then out[#out + 1] = buf end
    return out
end

--- 从响应头收集 set-cookie（luasocket header 表可能多值叠成串或表）
function Cookies:storeFromResponse(url, resheaders)
    local setcookies = resheaders and (resheaders["set-cookie"]
                                       or resheaders["Set-Cookie"])
    if not setcookies then return end
    if type(setcookies) == "string" then
        setcookies = splitSetCookie(setcookies)
    else
        -- 表形态（KOReader http 层）逐条同样拆分，防同类合并
        local expanded = {}
        for _, sc in ipairs(setcookies) do
            for _, piece in ipairs(splitSetCookie(sc)) do
                expanded[#expanded + 1] = piece
            end
        end
        setcookies = expanded
    end
    local now = self.now() * 1000
    for _, sc in ipairs(setcookies) do
        -- 朴素解析 name=value; a=b; ...
        local parts = {}
        for seg in sc:gmatch("[^;]+") do
            local k, v = seg:match("^%s*([^=]+)=?(.-)%s*$")
            if k then parts[k:lower()] = v end
        end
        local n, v = sc:match("^%s*([^=;]+)=([^;]*)")
        if n then
            local cookie = {
                name = n, value = v,
                domain = parts["domain"] or hostOf(url),
                path = parts["path"] or "/",
                expires = -1,
                secure = parts["secure"] ~= nil,
                httpOnly = parts["httponly"] ~= nil,
            }
            -- 审查 L9（独立报告）：非法 max-age（tonumber 为 nil）会在
            -- `nil * 1000` 处抛算术错误，被 bridge 的 pcall 吞掉后
            -- 连带丢弃本响应后续所有 Set-Cookie。RFC 6265 §5.2.2：
            -- max-age 非法时忽略该属性，回退 Expires / 会话语义。
            local ma = tonumber(parts["max-age"])
            if ma then
                cookie.expires = now + ma * 1000
            elseif parts["expires"] then
                cookie.expires = Cookies.parseHttpDate(parts["expires"])
                    or -1
            end
            self:setCookies(url, { cookie })
        end
    end
end

-- RFC1123/HTTP date 粗解析（常见格式），失败返回 nil
local MONTHS = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
                 jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }
function Cookies.parseHttpDate(s)
    if type(s) ~= "string" then return nil end
    -- 审查 M8：原实现 "%a+,s*" 中 s* 是字面字符 's'（少一个 %），RFC1123
    -- 日期永远匹配失败 → 会话 cookie 永不过期。改为不依赖星期前缀，
    -- 直接定位 "06 Nov 1994 08:49:37" 主体（对有无星期前缀都兼容）。
    local d, mon, y, h, m, sec =
        s:match("(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)")
    if d and MONTHS[mon:lower()] then
        return os.time({ day = tonumber(d), month = MONTHS[mon:lower()],
                         year = tonumber(y), hour = tonumber(h),
                         min = tonumber(m), sec = tonumber(sec) }) * 1000
    end
    return nil
end

return Cookies
