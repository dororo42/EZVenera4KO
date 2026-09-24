--[[
EZVenera for KOReader — library.lua
收藏夹 + 阅读历史（持久化）。

动机（真机反馈）：源 → 分类 → 结果 → 详情 → 章节 五层菜单每次回看都要重走，
而且源站列表/详情是一次性网络请求。收藏与历史让"回到上次看的章节"变成一次点击。

设计约束：
* ADR-005 —— 只用普通菜单项 + ConfirmBox，不依赖长按（hold）。
* 与 KOReader 解耦：存储走注入的 settings（LuaSettings 后端 / 测试用内存后端），
  这样模块能在 scripts/run_tests.py 的纯 LuaJIT 环境下单测。
* 顺序：两个列表都是**最新在前**（数组第 1 项 = 最近一条），读取端直接渲染即可。
]]

local Library = {}
Library.__index = Library

Library.HISTORY_MAX = 60
Library.FAV_MAX = 300

function Library.new(settings)
    local o = setmetatable({}, Library)
    o.settings = settings
    return o
end

local function nowSec()
    local ok, t = pcall(os.time)
    if ok and type(t) == "number" then return t end
    return 0
end

function Library:_read(key)
    local v = self.settings:get(key)
    if type(v) ~= "table" then return {} end
    return v
end

function Library:_write(key, list)
    self.settings:set(key, list)
end

--- 同一本书（source key + comicId）只留一条，新的置顶
local function upsert(list, idOf, entry, cap)
    local id = idOf(entry)
    for i = #list, 1, -1 do
        if idOf(list[i]) == id then table.remove(list, i) end
    end
    table.insert(list, 1, entry)
    while #list > cap do table.remove(list, #list) end
    return list
end

-- ---------- 收藏夹 ----------

function Library:listFavorites() return self:_read("favorites") end

local function favIdOf(f) return tostring(f.key) .. "\1" .. tostring(f.comicId) end

function Library:isFavorite(key, comicId)
    local want = tostring(key) .. "\1" .. tostring(comicId)
    for _, f in ipairs(self:listFavorites()) do
        if favIdOf(f) == want then return true end
    end
    return false
end

--- 切换收藏状态。返回切换后的状态（true = 已收藏）。
function Library:toggleFavorite(entry)
    local list = self:listFavorites()
    local want = favIdOf(entry)
    for i = #list, 1, -1 do
        if favIdOf(list[i]) == want then
            table.remove(list, i)
            self:_write("favorites", list)
            return false
        end
    end
    local e = {
        key = entry.key, comicId = entry.comicId,
        title = entry.title or entry.comicTitle or "",
        added = nowSec(),
    }
    upsert(list, favIdOf, e, self.FAV_MAX)
    self:_write("favorites", list)
    return true
end

function Library:removeFavorite(key, comicId)
    local list = self:listFavorites()
    local want = tostring(key) .. "\1" .. tostring(comicId)
    local removed = false
    for i = #list, 1, -1 do
        if favIdOf(list[i]) == want then
            table.remove(list, i)
            removed = true
        end
    end
    if removed then self:_write("favorites", list) end
    return removed
end

function Library:clearFavorites() self:_write("favorites", {}) end

-- ---------- 阅读历史 ----------

function Library:listHistory() return self:_read("history") end

local function histIdOf(h) return tostring(h.key) .. "\1" .. tostring(h.comicId) end

--- 记录"读到某本书的某一章"。同一本书只留一条（覆盖章节 + 置顶）。
function Library:recordRead(entry)
    local list = self:listHistory()
    local e = {
        key = entry.key, comicId = entry.comicId,
        title = entry.title or "", epId = entry.epId, epTitle = entry.epTitle,
        read = nowSec(),
    }
    upsert(list, histIdOf, e, self.HISTORY_MAX)
    self:_write("history", list)
    return e
end

function Library:clearHistory() self:_write("history", {}) end

return Library
