--[[
EZVenera for KOReader — runtime/sourcedata.lua

按源本地数据（<dataDir>/ezvenera/data/<源key>.json）的统一读写入口。

上游 EZVenera 的语义（lib/src/plugin_runtime/engine/plugin_js_engine.dart）：
  load_setting  → source.data['settings'][key] ?? 源声明的 default
  save_data     → source.data[data_key]
也就是说**源参数就存在源数据文件的 settings 槽里**，没有独立的设置库。
插件侧的配置界面必须写同一个位置，否则 JS 侧 loadSetting 读不到。

原先这份存储是 bridge.lua 里的 defaultStorage（只有 Lua 桥用）。抽出来共用，
避免界面和桥各写一份文件、互相看不到。
]]

local SourceData = {}
SourceData.__index = SourceData

SourceData.SETTINGS_SLOT = "settings"

--- 默认落盘存储：{ load(key) → map, save(key, map) → bool }
function SourceData.makeStorage()
    local ok, DataStorage = pcall(require, "datastorage")
    local basedir
    if ok and DataStorage then
        basedir = DataStorage:getDataDir() .. "/ezvenera/data"
    else
        basedir = "ezvenera/data"
    end
    local jsonmod = nil
    local okj, json = pcall(require, "json")
    if okj and json then jsonmod = json end
    local function pathfor(key)
        -- 审查 L10（独立报告）：key 来自 JS 源（不可信），含 `/`、`..` 等
        -- 可在数据目录内路径穿越读写其它 .json。压平为 [A-Za-z0-9_-]。
        -- （代价：不同 key 压平后可能碰撞，如 "a/b" 与 "a_b"；可接受。）
        local safe = tostring(key):gsub("[^%w%-_]", "_")
        return ("%s/%s.json"):format(basedir, safe)
    end
    local function ensureDir()
        -- R-D2v4（见 runtime/sources.lua）：优先用 KOReader 内建 lfs 逐级建
        -- 目录。os.execute 在安卓上会绕到 Java 端 fork 一个 sh，进程内已实测
        -- 有风险，只在没有 lfs 的测试环境里兜底。
        local oklfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not (oklfs and lfs and lfs.mkdir) then
            pcall(os.execute, 'mkdir -p "' .. basedir .. '" 2>/dev/null')
            return
        end
        local acc = basedir:sub(1, 1) == "/" and "" or nil
        for part in basedir:gmatch("[^/]+") do
            if acc == nil then acc = part else acc = acc .. "/" .. part end
            pcall(lfs.mkdir, acc)
        end
    end
    return {
        --- 整份删掉（源被移除时用：留空 {} 等于把 token/参数文件留在盘上）。
        --- 返回 true 表示文件已不存在。
        delete = function(key)
            local path = pathfor(key)
            if os.remove(path) then return true end
            -- 文件本来就不存在：同样算成功
            local f = io.open(path, "r")
            if not f then return true end
            f:close()
            return false
        end,
        load = function(key)
            if not jsonmod then return {} end
            local f = io.open(pathfor(key), "r")
            if not f then return {} end
            local data = f:read("*a")
            f:close()
            local okd, parsed = pcall(function()
                return jsonmod.decode(data)
            end)
            if okd and type(parsed) == "table" then return parsed end
            return {}
        end,
        save = function(key, map)
            if not jsonmod then return false end
            ensureDir()
            local oke, s = pcall(function() return jsonmod.encode(map) end)
            if not oke then return false end
            -- 审查 L10：temp+rename 原子写（中途崩溃/断电不产生半截 JSON）
            local path = pathfor(key)
            local tmp = path .. ".tmp"
            local f = io.open(tmp, "w")
            if not f then return false end
            f:write(s)
            f:close()
            if os.rename(tmp, path) then return true end
            -- 个别平台 rename 不能覆盖已存在文件：退回直写并清理 tmp
            local f2 = io.open(path, "w")
            if not f2 then return false end
            f2:write(s)
            f2:close()
            pcall(function() os.remove(tmp) end)
            return true
        end,
    }
end

--- deps: { storage = {load=,save=} }（单测注入内存后端）
function SourceData.new(deps)
    deps = deps or {}
    local o = setmetatable({}, SourceData)
    o.storage = deps.storage or SourceData.makeStorage()
    return o
end

function SourceData:load(key)
    local map = self.storage.load(key)
    if type(map) ~= "table" then return {} end
    return map
end

function SourceData:save(key, map)
    return self.storage.save(key, map or {}) == true
end

--- 已保存的源参数表（未设置过的键不存在，与"值为 nil"同义）
function SourceData:allSettings(key)
    local s = self:load(key)[SourceData.SETTINGS_SLOT]
    return type(s) == "table" and s or {}
end

function SourceData:getSetting(key, setting_key)
    local v = self:allSettings(key)[setting_key]
    if v == nil then return nil end
    return v
end

--- 写入单个参数。value 为 nil 时删除该键（回到源声明的 default）。
function SourceData:setSetting(key, setting_key, value)
    local map = self:load(key)
    local slot = map[SourceData.SETTINGS_SLOT]
    if type(slot) ~= "table" then
        slot = {}
        map[SourceData.SETTINGS_SLOT] = slot
    end
    slot[setting_key] = value
    return self:save(key, map)
end

--- 清空该源的本地数据（token、账号缓存、参数全在同一个文件里）。
function SourceData:clear(key)
    return self:save(key, {})
end

--- 连文件一起删除（源被移除时用）。旧的后端/测试桩没有 delete 时退化成
--- 写空表——清不掉内容不算 purge 的目标准，但也不能因此抛错。
function SourceData:purge(key)
    if self.storage and self.storage.delete then
        return self.storage.delete(key) and true or false
    end
    return self:save(key, {})
end

--- 只清参数槽（等价上游的"恢复默认"：删掉已存值，loadSetting 回落到
--- 源声明的 default）。整份数据（token 等）不动。
function SourceData:clearSettings(key)
    local map = self:load(key)
    map[SourceData.SETTINGS_SLOT] = nil
    return self:save(key, map)
end

--- 登录态判定。逐条对齐上游 models.dart 的 `bool get isLogged`
--- （_ez_logged → account → 非空 _localStorage），不要在这里加"顺手"规则：
--- 桥侧 isLogged 消息和界面显示必须给源同一个答案。
function SourceData.isLoggedMap(map)
    if type(map) ~= "table" then return false end
    if map["_ez_logged"] == true then return true end
    if map["account"] ~= nil then return true end
    local ls = map["_localStorage"]
    return type(ls) == "table" and next(ls) ~= nil
end

function SourceData:isLogged(key)
    return SourceData.isLoggedMap(self:load(key))
end

--- 上游 markLoggedIn/markLoggedOut：登录成功由**宿主**打标记（多数源只
--- saveData('token')，不会自己置位），注销则清掉标记与账号缓存。
function SourceData:markLoggedIn(key, account_data)
    local map = self:load(key)
    map["_ez_logged"] = true
    if account_data ~= nil then map["account"] = account_data end
    return self:save(key, map)
end

function SourceData:markLoggedOut(key)
    local map = self:load(key)
    map["_ez_logged"] = false
    map["account"] = nil
    map["_localStorage"] = nil
    return self:save(key, map)
end

return SourceData
