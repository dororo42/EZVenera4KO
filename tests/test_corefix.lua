-- unit test: corefix.lua
local CoreFix = require("corefix")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
end

local tests = {}

-- 复刻 KOReader booklist.lua:47 的 access 比较器：attr 缺失时抛错
local function accessSort()
    return function(a, b)
        return a.attr.access > b.attr.access
    end
end

function tests.nil_attr_no_longer_raises()
    local collates = { access = { init_sort_func = accessSort } }
    local done = CoreFix.harden(collates)
    assert_eq("one sorter hardened", 1, #done)
    local cmp = collates.access.init_sort_func()
    local items = {
        { path = "b", attr = { access = 5 } },
        { path = "a", attr = {} },          -- 拿不到 atime
        { path = "c", attr = { access = 9 } },
    }
    -- 回归锚点是“不抛错”本身：比较器不一致时不保证精确顺序
    local okerr = pcall(table.sort, items, cmp)
    assert_eq("sort survives nil attr", true, okerr)
    assert_eq("all rows kept", 3, #items)
    return true
end

function tests.hardening_is_idempotent()
    local collates = { access = { init_sort_func = accessSort } }
    CoreFix.harden(collates)
    local first = collates.access.init_sort_func
    local done2 = CoreFix.harden(collates)
    assert_eq("second pass is a no-op", 0, #done2)
    assert_eq("same wrapper kept", first, collates.access.init_sort_func)
    return true
end

function tests.text_funcs_degrade_to_empty()
    local collates = {
        access = {
            init_sort_func = accessSort,
            mandatory_func = function(item)
                return tostring(math.floor(item.attr.access / 1000)) .. "d"
            end,
        },
    }
    CoreFix.harden(collates)
    assert_eq("good value kept", "5d",
        collates.access.mandatory_func({ attr = { access = 5000 } }))
    assert_eq("nil attr shows empty", "",
        collates.access.mandatory_func({ attr = {} }))
    return true
end

function tests.non_function_sorter_passes_through()
    local collates = { weird = { init_sort_func = function() return nil end } }
    CoreFix.harden(collates)
    assert_eq("nil comparator untouched", nil, collates.weird.init_sort_func())
    return true
end

function tests.install_never_throws_outside_koreader()
    -- 单测环境没有 ui/widget/booklist：必须返回 false 而不是抛错
    local ok, detail = CoreFix.install()
    assert_eq("install reports failure", false, ok)
    assert_eq("failure reason", "booklist unavailable", detail)
    return true
end

return tests
