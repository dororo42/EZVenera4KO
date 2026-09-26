-- unit test: 菜单右对齐列（mandatory）宽度裁剪
-- 背景（2026-09-26 真机回归）：A漫 v2.0.0 的章节 id 是绝对 URL（aman.js:208
-- `cid = this.abs(href)`），塞进 mandatory 后 KOReader 的 menu.lua:202 算出
-- 标题可用宽度 <= 0 → textboxwidget.lua:879 `makeLine: width must be strictly
-- positive`，点进详情弹「操作失败」。裁剪按码点计数，切坏 UTF-8 会显示乱码。

local noop = function() end
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end

local fake = { shown = {} }

stub("logger", { warn = noop, info = noop, err = noop, dbg = noop, verbose = noop })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", {
    show = function(_, w) table.insert(fake.shown, w) end,
    close = noop,
    scheduleIn = noop,
    setDirty = noop,
})
stub("ui/widget/menu", {
    new = function(_, args) return { __menu = true, args = args } end,
})
stub("ui/widget/infomessage", { new = function(_, a) return a end })

package.loaded["browser"] = nil
local Browser = require("browser")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local tests = {}

function tests.short_values_pass_through()
    assert_eq("nil 仍为 nil", nil, Browser.shortMandatory(nil))
    -- 空串是既有语义（未知登录态那行传 ""），不改
    assert_eq("空串原样返回", "", Browser.shortMandatory(""))
    assert_eq("短 ASCII 不变", "1.0.2", Browser.shortMandatory("1.0.2"))
    assert_eq("数字转字符串", "12", Browser.shortMandatory(12))
    return true
end

function tests.long_id_keeps_tail()
    local url = "https://aman8.org/manhuachapter/459293_12.html"
    local got = Browser.shortMandatory(url)
    assert_eq("长 id 裁到尾部 16 个码点", "…r/459293_12.html", got)
    -- 省略号是 3 字节 UTF-8 序列：断言的是字节数，防按字节切
    assert_eq("结果字节长度 = 3 + 16", 19, #got)
    return true
end

function tests.cjk_not_cut_mid_character()
    -- 20 个三字节汉字 → 保留后 16 个；若按字节切会留下半个序列
    local s = string.rep("漢", 20)
    local got = Browser.shortMandatory(s)
    assert_eq("汉字按码点计数", "…" .. string.rep("漢", 16), got)
    return true
end

function tests.nav_menu_clamps_every_row()
    local b = setmetatable({}, { __index = Browser })
    local items = {
        { text = "第 1 话", mandatory = "https://aman8.org/manhuachapter/1.html" },
        { text = "第 2 话", mandatory = "12" },
        { text = "无右列" },
    }
    local menu = b:_navMenu({ title = "t", item_table = items })
    assert_eq("长 mandatory 已裁短", "…uachapter/1.html", menu.args.item_table[1].mandatory)
    assert_eq("短 mandatory 不动", "12", menu.args.item_table[2].mandatory)
    assert_eq("nil 保持 nil", nil, menu.args.item_table[3].mandatory)
    return true
end

return tests
