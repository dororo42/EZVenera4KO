-- unit test: library.lua —— 收藏夹 + 阅读历史的本地存储
-- （真机反馈：回看一本书要重走 源→分类→结果→详情→章节 五层）
local Library = require("library")
local stubs = require("tests.stubs")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
end

local function newLib()
    return Library.new(stubs.settings_memory())
end

local tests = {}

function tests.empty_lists_by_default()
    local lib = newLib()
    assert_eq("favorites empty", 0, #lib:listFavorites())
    assert_eq("history empty", 0, #lib:listHistory())
    assert_eq("not favorite", false, lib:isFavorite("baozi", "c1"))
    return true
end

function tests.favorite_toggle_round_trip()
    local lib = newLib()
    assert_eq("add returns true", true,
        lib:toggleFavorite{ key = "baozi", comicId = "c1", title = "大理寺日志" })
    assert_eq("now favorite", true, lib:isFavorite("baozi", "c1"))
    assert_eq("one row", 1, #lib:listFavorites())
    assert_eq("收藏按源隔离", false, lib:isFavorite("copy_manga", "c1"))
    assert_eq("toggle again removes", false,
        lib:toggleFavorite{ key = "baozi", comicId = "c1" })
    assert_eq("empty again", 0, #lib:listFavorites())
    return true
end

function tests.favorite_rows_carry_title_for_the_menu()
    local lib = newLib()
    lib:toggleFavorite{ key = "baozi", comicId = "c1", title = "航海王" }
    local f = lib:listFavorites()[1]
    assert_eq("title", "航海王", f.title)
    assert_eq("source key", "baozi", f.key)
    assert_eq("comic id", "c1", f.comicId)
    return true
end

function tests.history_keeps_one_row_per_book()
    local lib = newLib()
    lib:recordRead{ key = "baozi", comicId = "c1", title = "A" }
    lib:recordRead{ key = "baozi", comicId = "c2", title = "B" }
    -- 同一本书读到第 7 话：合并进原来那条，并顶到最前
    lib:recordRead{ key = "baozi", comicId = "c1", title = "A",
        epId = "7", epTitle = "第7话" }
    local h = lib:listHistory()
    assert_eq("两本书两条", 2, #h)
    assert_eq("最近看的在最前", "c1", h[1].comicId)
    assert_eq("章节已合并", "7", h[1].epId)
    assert_eq("章节名已合并", "第7话", h[1].epTitle)
    return true
end

function tests.history_caps_and_keeps_newest()
    local lib = newLib()
    for i = 1, Library.HISTORY_MAX + 10 do
        lib:recordRead{ key = "s", comicId = "c" .. i, title = "t" }
    end
    local h = lib:listHistory()
    assert_eq("封顶", Library.HISTORY_MAX, #h)
    assert_eq("最新在第一位", "c" .. (Library.HISTORY_MAX + 10), h[1].comicId)
    return true
end

function tests.clear_and_remove()
    local lib = newLib()
    lib:toggleFavorite{ key = "baozi", comicId = "c1", title = "A" }
    lib:toggleFavorite{ key = "baozi", comicId = "c2", title = "B" }
    lib:recordRead{ key = "baozi", comicId = "c3", title = "C" }
    assert_eq("remove one fav", true, lib:removeFavorite("baozi", "c1"))
    assert_eq("remove missing", false, lib:removeFavorite("baozi", "c9"))
    assert_eq("剩一条", 1, #lib:listFavorites())
    lib:clearFavorites()
    lib:clearHistory()
    assert_eq("收藏清空", 0, #lib:listFavorites())
    assert_eq("历史清空", 0, #lib:listHistory())
    return true
end

function tests.data_survives_new_instance()
    -- 真机上每次进插件都会 new 一个 Library；数据必须落在 settings 后端里
    local s = stubs.settings_memory()
    Library.new(s):recordRead{ key = "baozi", comicId = "c1", title = "A",
        epId = "3", epTitle = "第3话" }
    local reopened = Library.new(s)
    assert_eq("重开可读", 1, #reopened:listHistory())
    assert_eq("章节保留", "3", reopened:listHistory()[1].epId)
    return true
end

function tests.corrupt_storage_degrades_to_empty()
    local s = stubs.settings_memory()
    s:set("favorites", false)     -- Settings:get 的缺省值形态
    s:set("history", "garbage")
    local lib = Library.new(s)
    assert_eq("收藏降级为空", 0, #lib:listFavorites())
    assert_eq("历史降级为空", 0, #lib:listHistory())
    return true
end

return tests
