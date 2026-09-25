-- unit test: browser.lua 的 optionList → options 组装（R7 排行榜错位修复）
-- browser.lua 顶层 require KOReader 前端模块，测试环境没有 → preload 桩。

local noop = function() end
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end

stub("logger", { warn = noop, info = noop, err = noop, dbg = noop, verbose = noop })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", { show = noop, close = noop, scheduleIn = noop })
stub("ui/widget/menu", { new = noop })
stub("ui/widget/infomessage", { new = noop })

local Browser = require("browser")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

--- 只替 _awaitSource：optionList 声明直接由表提供
local function makeBrowser(decls)
    local b = setmetatable({}, { __index = Browser })
    b._awaitSource = function(_, _key, path) return decls[path] end
    return b
end

local tests = {}

-- 再漫画形状：4 个分类组 + 1 个排行组（showWhen 为数组）
local ZAIMANHUA = {
    { options = { "1-更新", "2-人气" }, showWhen = { "少年", "少女" } },
    { options = { "0-全部", "3262-少年漫画" }, showWhen = { "少年", "少女" } },
    { options = { "0-全部", "2309-连载中" }, showWhen = { "少年", "少女" } },
    { options = { "0-全部", "2304-日本" }, showWhen = { "少年", "少女" } },
    { options = { "0-人气", "1-吐槽" }, showWhen = { "日排行", "周排行" } },
}

-- 真机症状回归：排行榜必须只剩排行组，否则源里 options[0]/[1] 取到分类组的值
function tests.rank_category_keeps_only_rank_groups()
    local b = makeBrowser({ ["categoryComics.optionList"] = ZAIMANHUA })
    local o = b:_defaultOptions("z", "categoryComics", "日排行")
    assert_eq("len", 1, #o)
    assert_eq("value", "0", o[1])
    return true
end

function tests.normal_category_keeps_category_groups_in_order()
    local b = makeBrowser({ ["categoryComics.optionList"] = ZAIMANHUA })
    local o = b:_defaultOptions("z", "categoryComics", "少年")
    -- zaimanhua.js:224 按 sortType=options[0]、cate=[1]、status=[2]、zone=[3]
    assert_eq("len", 4, #o)
    assert_eq("sortType", "1", o[1])
    assert_eq("cate", "0", o[2])
    assert_eq("status", "0", o[3])
    assert_eq("zone", "0", o[4])
    return true
end

-- copy_manga 形状：`*` 属于 value（:638 比的是 "*all"，:635 把 "*x"→"-x"）
function tests.star_prefix_is_part_of_value()
    local decl = {
        { options = { "*all-全部", "0-日漫" }, showWhen = { "全部", "日漫" } },
        { options = { "*datetime_updated-时间倒序", "datetime_updated-时间正序" },
          showWhen = { "全部", "日漫" } },
        { options = { "male-男频", "female-女频" }, showWhen = { "排行" } },
        { options = { "day-上升最快", "week-最近7天" }, showWhen = { "排行" } },
    }
    local b = makeBrowser({ ["categoryComics.optionList"] = decl })
    local cat = b:_defaultOptions("c", "categoryComics", "全部")
    assert_eq("star kept (filter)", "*all", cat[1])
    assert_eq("star kept (ordering)", "*datetime_updated", cat[2])
    local rank = b:_defaultOptions("c", "categoryComics", "排行")
    assert_eq("rank len", 2, #rank)
    assert_eq("rank type", "male", rank[1])
    assert_eq("rank table", "day", rank[2])
    return true
end

-- 首个选项 value 为空串（"-全部"）：占位必须保留，不能整组消失
function tests.empty_value_option_keeps_slot()
    local decl = { { options = { "-全部", "name-名称" } } }
    local b = makeBrowser({ ["search.optionList"] = decl })
    local o = b:_defaultOptions("c", "search", "search")
    assert_eq("len", 1, #o)
    assert_eq("empty value kept", "", o[1])
    return true
end

function tests.showwhen_string_array_and_notshowwhen()
    local decl = {
        { options = { "a-A" }, showWhen = "search" },
        { options = { "b-B" }, notShowWhen = "search" },
        { options = { "c-C" } },                    -- 无限制
        { options = { "d-D" }, showWhen = "" },      -- 空串 = 不限制
        { options = { "e-E" }, showWhen = {} },      -- 空数组 = 不限制
        -- JSON null 解出来是 cjson.null（truthy 的 lightuserdata）→ 非
        -- string 一律按"无限制"处理，否则整组被误隐藏
        { options = { "f-F" }, notShowWhen = 0, showWhen = { "排行" } },
    }
    local b = makeBrowser({ ["search.optionList"] = decl })
    assert_eq("search ctx", "a,c,d,e",
        table.concat(b:_defaultOptions("s", "search", "search"), ","))
    assert_eq("category ctx", "b,c,d,e,f",
        table.concat(b:_defaultOptions("s", "search", "排行"), ","))
    return true
end

function tests.flat_optionlist_and_missing_member()
    local b = makeBrowser({
        ["search.optionList"] = { "x-X", "y-Y" },   -- 扁平：整串即一项
    })
    local o = b:_defaultOptions("s", "search", "search")
    assert_eq("flat len", 2, #o)
    assert_eq("flat first", "x", o[1])
    local b2 = makeBrowser({})                       -- 源无该成员
    assert_eq("missing → empty", 0, #b2:_defaultOptions("s", "search", "search"))
    return true
end

-- 漏传 ctx（旧调用形状）不得抛错：按 "" 处理，showWhen 组自然过滤掉
function tests.nil_ctx_tolerated()
    local b = makeBrowser({ ["categoryComics.optionList"] = ZAIMANHUA })
    assert_eq("no visible group", 0, #b:_defaultOptions("z", "categoryComics"))
    return true
end

-- 三个调用点必须都带上上下文，否则排行榜/搜索仍拿到错位的 options
function tests.call_sites_pass_context()
    local f = assert(package.searchpath("browser", package.path))
    local src = assert(io.open(f, "rb")):read("a")
    local n = 0
    for call in src:gmatch('self:_defaultOptions%(([^%)]*)%)') do
        n = n + 1
        local commas = select(2, call:gsub(",", ""))
        assert_eq("call site has ctx arg: " .. call, 2, commas)
    end
    assert_eq("three call sites", 3, n)
    return true
end

return tests
