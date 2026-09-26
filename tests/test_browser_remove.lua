-- unit test: browser.lua 的源删除链路（单源菜单 + 批量多选删除）
-- 两条真机教训住在这里：
--   ① 源菜单曾直接索引 JSON null 哨兵（logcat：attempt to index local 'acc'
--      (a function value)）→ 菜单打不开，里面的「删除源」永远点不到。
--   ② 整包导入 30 个源后要清，只能一个个进菜单删（用户要求多选删除）。
-- ADR-005：所有行都是普通 callback（本文件最后一个测试静态检 hold_*）。
-- browser.lua 顶层 require KOReader 前端模块 → 测试环境先桩化。

local noop = function() end
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end

local fake = { shown = {}, closed = {} }

stub("logger", { warn = noop, info = noop, err = noop, dbg = noop, verbose = noop })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", {
    show = function(_, w) table.insert(fake.shown, w) end,
    close = function(_, w) table.insert(fake.closed, w) end,
    scheduleIn = noop,
    setDirty = noop,
})
stub("ui/widget/menu", {
    new = function(_, args) return { __menu = true, args = args } end,
})
stub("ui/widget/infomessage", { new = function(_, a) return a end })
stub("ui/widget/confirmbox", {
    new = function(_, a) return { __confirm = true, args = a } end,
})

package.loaded["browser"] = nil
local Browser = require("browser")
local JsHost = require("runtime/jshost")
local SourceData = require("runtime/sourcedata")

local tests = {}

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function lastMenu()
    for i = #fake.shown, 1, -1 do
        local w = fake.shown[i]
        if type(w) == "table" and w.__menu then return w end
    end
end

local function lastConfirm()
    for i = #fake.shown, 1, -1 do
        local w = fake.shown[i]
        if type(w) == "table" and w.__confirm then return w end
    end
end

local function texts(rows)
    local o = {}
    for _, r in ipairs(rows or {}) do table.insert(o, r.text) end
    return table.concat(o, "|")
end

--- sources 桩：listInstalled 给固定表，remove 记调用并可指定失败 key
local function fakeSources(list, fail_map)
    local st = { list = list, removed = {}, fail = fail_map or {},
        backups = {}, restored = {} }
    function st:listInstalled() return self.list end
    function st.uniqueLabels(list)
        local o = {}
        for i, e in ipairs(list) do o[i] = e.name or e.key end
        return o
    end
    function st:listBackups() return self.backups end
    function st:restoreBackup(key, version)
        table.insert(self.restored, key .. "@" .. tostring(version))
        return true, { key = key, version = version }
    end
    function st:remove(key)
        if self.fail[key] then return false, self.fail[key] end
        for i, e in ipairs(self.list) do
            if e.key == key then
                table.remove(self.list, i)
                table.insert(self.removed, key)
                return true
            end
        end
        return false, "not installed: " .. tostring(key)
    end
    return st
end

local function makeB(opts)
    opts = opts or {}
    local purged = {}
    local b = setmetatable({}, { __index = Browser })
    b.messages = {}
    b.infoMessage = function(t) table.insert(b.messages, t) end
    b.sources = opts.sources
    b.engine = opts.engine
    b._registered = opts.registered or {}
    b.sourcedata = { purge = function(_, key) table.insert(purged, key) end,
        isLogged = function() return false end, allSettings = function() return {} end }
    b._purged = purged
    b._ensureSourceLoaded = opts.ensure or function(_, key)
        return (b._registered[key] ~= false) and ("js:" .. key) or nil, "无法加载"
    end
    return b
end

-- ---- ① 源菜单：null 哨兵不得再让菜单打不开 ----

function tests.source_menu_survives_null_sentinel_account()
    fake.shown = {}
    -- 未剥哨兵的 info（模拟旧解码结果 / 引擎给了怪东西）：必须是 function 才
    -- 复现真机那条 logcat
    local b = makeB({ engine = {
        sourceInfo = function()
            return { settings = {}, account = function() end }
        end,
    } })
    b:showSourceMenu("czmanga", "包子漫画cn", "1.0.0")
    local m = lastMenu()
    assert(m, "菜单必须显示（旧版在这里抛错）")
    assert_eq("没有账号能力就不出登录/注销行",
        "源信息|参数配置…|清除本地数据（含登录态）|删除源…",
        texts(m.args.item_table))
    return true
end

function tests.source_menu_keeps_account_rows_for_real_account()
    fake.shown = {}
    local b = makeB({ engine = {
        sourceInfo = function()
            return { settings = {}, account = { login = true, logout = false,
                website = "https://example.com/login" } }
        end,
    } })
    b:showSourceMenu("picacg", "Picacg", "1.0.5")
    local m = lastMenu()
    assert_eq("登录/网址行按声明出现，注销按声明缺席",
        "源信息|参数配置…|账号登录…|注册/登录网址|清除本地数据（含登录态）|删除源…",
        texts(m.args.item_table))
    return true
end

function tests.source_menu_info_row_shows_declaration_error()
    fake.shown = {}
    local b = makeB({ engine = {
        -- 双返回值：错误串不能被丢进 info
        sourceInfo = function() return nil, "bad schema JSON: xyz" end,
    } })
    b:showSourceMenu("broken", "坏源", "1")
    local m = lastMenu()
    local info_row = m.args.item_table[1]
    assert_eq("首行是源信息", true, info_row.info_row)
    b.messages = {}
    m.args.onMenuSelect(m, info_row)
    assert_eq("一条提示", 1, #b.messages)
    assert(b.messages[1]:find("bad schema JSON", 1, true),
        "信息行要带上声明读取失败原因: " .. b.messages[1])
    return true
end

-- ---- ①b 覆盖护栏的退路：有备份才给「回退到旧版」入口 ----

local function menuWithBackups(backups)
    fake.shown = {}
    local st = fakeSources({ { key = "a", name = "甲", version = "1.0.2" } })
    st.backups = backups
    local b = makeB({ sources = st, engine = {
        sourceInfo = function() return { settings = {} } end,
    } })
    b:showSourceMenu("a", "甲", "1.0.2")
    return b, st, lastMenu()
end

function tests.source_menu_rollback_row_only_with_backups()
    local _, _, m = menuWithBackups({})
    assert_eq("没备份 → 没有回退行",
        "源信息|参数配置…|清除本地数据（含登录态）|删除源…",
        texts(m.args.item_table))
    local _, _, m2 = menuWithBackups{
        { version = "1.0.0", file = "/x/a.js.bak-1.0.0" },
    }
    assert_eq("有备份 → 给出入口（仍是普通菜单项，ADR-005）",
        "源信息|参数配置…|清除本地数据（含登录态）|回退到旧版…|删除源…",
        texts(m2.args.item_table))
    return true
end

function tests.rollback_flow_restores_and_invalidates()
    local b, st, m = menuWithBackups{
        { version = "1.0.0", file = "/x/a.js.bak-1.0.0" },
    }
    local row
    for _, r in ipairs(m.args.item_table) do
        if r.restore_row then row = r end
    end
    b.invalidated = {}
    b.invalidateSource = function(_, key) table.insert(b.invalidated, key) end
    m.args.onMenuSelect(m, row)                      -- 打开备份列表
    local list_menu = lastMenu()
    assert(list_menu, "点回退行应打开备份列表")
    local pick
    for _, r in ipairs(list_menu.args.item_table) do
        if r.backup then pick = r end
    end
    assert(pick, "备份列表里要给出一条可点的行")
    assert_eq("文案带目标版本号", "回退到 v1.0.0", pick.text)
    list_menu.args.onMenuSelect(list_menu, pick)
    local confirm = lastConfirm()
    assert(confirm, "回退要先确认（改的是已装源文件）")
    confirm.args.ok_callback()
    assert_eq("按备份版本号回退", 1, #st.restored)
    assert_eq("回退调用", "a@1.0.0", st.restored[1])
    assert_eq("回退后要作废引擎缓存", 1, #b.invalidated)
    assert_eq("key", "a", b.invalidated[1])
    assert_eq("提示一次", 1, #b.messages)
    assert(b.messages[1]:find("已回退到 v1.0.0", 1, true),
        "要说清回到了哪一版: " .. b.messages[1])
    return true
end

-- ---- ② 批量多选删除 ----

local function threeSources()
    return fakeSources({
        { key = "a", name = "甲", version = "1" },
        { key = "b", name = "乙", version = "1" },
        { key = "c", name = "丙", version = "1" },
    })
end

local function openMultiDelete(opts)
    fake.shown = {}
    local b = makeB(opts)
    b:showSourceMultiDelete()
    return b, lastMenu()
end

function tests.multi_delete_lists_every_source_unmarked()
    local b, m = openMultiDelete({ sources = threeSources() })
    assert_eq("标题带总数", "批量删除源（0/3）", m.args.title)
    assert_eq("3 个源 + 说明 + 3 个动作行", 7, #(m.args.item_table))
    assert_eq("未选中是 ○",
        "○ 甲|○ 乙|○ 丙|说明：点一行切换选中（◆=将删除）|全选|清空选择|删除所选（0）",
        texts(m.args.item_table))
    assert_eq("还没删", 0, #b.sources.removed)
    return true
end

function tests.multi_delete_toggle_marks_and_retitles()
    local b, m = openMultiDelete({ sources = threeSources() })
    m.args.onMenuSelect(m, m.args.item_table[1])
    local m2 = lastMenu()
    assert_eq("第一行变 ◆", "◆ 甲|○ 乙|○ 丙",
        texts(m2.args.item_table):match("^([^|]+%|[^|]+%|[^|]+)"))
    assert_eq("标题计数", "批量删除源（1/3）", m2.args.title)
    -- 再点一次取消（多选最容易犯的错：点第二下以为关闭菜单）
    m2.args.onMenuSelect(m2, m2.args.item_table[1])
    assert_eq("取消后回到 0", "批量删除源（0/3）", lastMenu().args.title)
    return true
end

function tests.multi_delete_select_all_then_clear()
    local _, m = openMultiDelete({ sources = threeSources() })
    local rows = m.args.item_table
    m.args.onMenuSelect(m, rows[5])                     -- 全选
    assert_eq("全选计数", "批量删除源（3/3）", lastMenu().args.title)
    local m2 = lastMenu()
    m2.args.onMenuSelect(m2, m2.args.item_table[6])     -- 清空选择
    assert_eq("清空计数", "批量删除源（0/3）", lastMenu().args.title)
    return true
end

function tests.multi_delete_asks_confirmation_before_removing()
    local b, m = openMultiDelete({ sources = threeSources() })
    m.args.onMenuSelect(m, m.args.item_table[1])        -- 选甲
    m.args.onMenuSelect(m, m.args.item_table[2])        -- 选乙
    local m2 = lastMenu()
    m2.args.onMenuSelect(m2, m2.args.item_table[7])     -- 删除所选（2）
    assert_eq("还没确认：一个都没删", 0, #b.sources.removed)
    local cb = lastConfirm()
    assert(cb, "必须二次确认")
    assert(cb.args.text:find("2 个源", 1, true), "确认文案要有数量: " .. cb.args.text)
    cb.args.ok_callback()
    assert_eq("确认后删两个", "a,b", table.concat(b.sources.removed, ","))
    assert_eq("汇总提示", 1, #b.messages)
    assert(b.messages[1]:find("已删除 2", 1, true), b.messages[1])
    assert_eq("剩一个源，菜单继续开着", "批量删除源（0/1）", lastMenu().args.title)
    return true
end

function tests.multi_delete_without_selection_says_so()
    local b, m = openMultiDelete({ sources = threeSources() })
    m.args.onMenuSelect(m, m.args.item_table[7])
    assert_eq("只提示", 1, #b.messages)
    assert(b.messages[1]:find("还没有选中", 1, true), b.messages[1])
    assert_eq("不弹确认框", nil, lastConfirm())
    return true
end

function tests.multi_delete_keeps_failed_rows_and_reports_them()
    local st = threeSources()
    st.fail = { b = "源文件删除失败（只读或被占用）" }
    local b, m = openMultiDelete({ sources = st })
    m.args.onMenuSelect(m, m.args.item_table[1])
    m.args.onMenuSelect(m, m.args.item_table[2])
    local m2 = lastMenu()
    m2.args.onMenuSelect(m2, m2.args.item_table[7])
    lastConfirm().args.ok_callback()
    assert_eq("成功的那个删了", "a", table.concat(b.sources.removed, ","))
    assert_eq("列表里还剩失败的", "b", b.sources.list[1].key)
    assert_eq("提示里两个数都有", 1, #b.messages)
    assert(b.messages[1]:find("已删除 1", 1, true), b.messages[1])
    assert(b.messages[1]:find("失败 1", 1, true), b.messages[1])
    assert(b.messages[1]:find("只读或被占用", 1, true), b.messages[1])
    return true
end

function tests.multi_delete_closes_menu_when_list_emptied()
    fake.closed = {}
    local b, m = openMultiDelete({ sources = threeSources() })
    m.args.onMenuSelect(m, m.args.item_table[5])        -- 全选
    local m2 = lastMenu()
    m2.args.onMenuSelect(m2, m2.args.item_table[7])
    lastConfirm().args.ok_callback()
    assert_eq("三个都删", 3, #b.sources.removed)
    assert(b.messages[1]:find("已清空", 1, true), b.messages[1])
    local closed_menu
    for _, w in ipairs(fake.closed) do
        if type(w) == "table" and w.__menu and w == m2 then closed_menu = true end
    end
    assert_eq("当前菜单被关掉（不留空菜单在屏上）", true, closed_menu)
    return true
end

function tests.multi_delete_empty_manifest_tells_user()
    fake.shown = {}
    local b = makeB({ sources = fakeSources({}) })
    b:showSourceMultiDelete()
    assert_eq("不建菜单", nil, lastMenu())
    assert(b.messages[1]:find("尚未安装", 1, true), b.messages[1])
    return true
end

-- KOReader 的 Menu 有 switchItemTable（原地换表）：有它就必须用，
-- 否则每点一下都关旧开新，翻页位置全丢。
-- 注意要**改桩表本身**：browser.lua 在 load 时就捕获了模块表引用。
function tests.multi_delete_reuses_switchItemTable()
    fake.shown = {}
    local switched = {}
    local menu_stub = package.loaded["ui/widget/menu"]
    local old_new = menu_stub.new
    menu_stub.new = function(_, args)
        local o = { __menu = true, args = args }
        function o:switchItemTable(title, rows)
            table.insert(switched, title)
            self.args.title, self.args.item_table = title, rows
        end
        return o
    end
    local _, m = openMultiDelete({ sources = threeSources() })
    local shown_before = #fake.shown
    m.args.onMenuSelect(m, m.args.item_table[3])
    menu_stub.new = old_new
    assert_eq("原地换表一次", 1, #switched)
    assert_eq("没有关旧开新", shown_before, #fake.shown)
    assert_eq("换表后标题", "批量删除源（1/3）", m.args.title)
    assert_eq("换表后行表也更新", "◆ 丙", m.args.item_table[3].text)
    return true
end

-- ---- 删除的收尾：本地数据文件也要清 ----

function tests.remove_source_purges_key_and_engine_key()
    local b = makeB({ sources = threeSources(),
        registered = { a = "js:czmanga" } })
    local ok, err = b:_removeSource("a")
    assert_eq("删除成功", true, ok)
    assert_eq("err", nil, err)
    assert_eq("两个 key 的数据都清", "a|js:czmanga",
        table.concat(b._purged, "|"))
    assert_eq("内存注册作废", nil, b._registered.a)
    return true
end

function tests.remove_source_reports_missing_storage()
    local b = makeB({})
    b.sources = nil
    local ok, err = b:_removeSource("a")
    assert_eq("失败", false, ok)
    assert(err ~= nil and err ~= "", "要有原因")
    assert_eq("没删数据", 0, #b._purged)
    return true
end

-- ---- JSON null 哨兵剥离（jshost 解码出口） ----

function tests.strip_nulls_drops_sentinels_deeply()
    local t = {
        account = function() end,          -- 纯 Lua json 的 null
        website = newproxy and newproxy(),  -- cjson 的 null（userdata/proxy）
        keep = "x", n = 0, list = { { a = function() end, b = "y" } },
    }
    JsHost.stripNulls(t)
    assert_eq("function 哨兵清掉", nil, t.account)
    assert_eq("userdata 哨兵清掉", nil, t.website)
    assert_eq("字符串保留", "x", t.keep)
    assert_eq("0 不是 null", 0, t.n)
    assert_eq("嵌套里的也清掉", nil, t.list[1].a)
    assert_eq("嵌套里的正常值保留", "y", t.list[1].b)
    assert_eq("非表原样返回", 5, JsHost.stripNulls(5))
    return true
end

function tests.strip_nulls_is_bounded_on_deep_nesting()
    local root = {}
    local cur = root
    for _ = 1, 200 do
        cur.child = {}
        cur = cur.child
    end
    cur.leaf = function() end
    local ok = pcall(function() JsHost.stripNulls(root) end)
    assert_eq("不爆栈", true, ok)
    return true
end

-- ---- 数据层：purge 有 delete 用 delete，没有就退化 ----

function tests.sourcedata_purge_deletes_file()
    local files = { picacg = { token = "t" }, locked = { x = 1 } }
    local sd = SourceData.new{ storage = {
        load = function(k) return files[k] or {} end,
        save = function(k, m) files[k] = m or {} return true end,
        -- 与真实后端一致：文件本来不存在也算删成功；只读文件报 false
        delete = function(k)
            if k == "locked" then return false end
            files[k] = nil
            return true
        end,
    } }
    assert_eq("purge ok", true, sd:purge("picacg"))
    assert_eq("文件真没了", nil, files.picacg)
    assert_eq("不存在的 key 无内容可清 = 成功", true, sd:purge("ghost"))
    assert_eq("后端拒绝时如实报失败", false, sd:purge("locked"))
    assert_eq("失败不能假装清空", 1, (function()
        local n = 0
        for _ in pairs(files.locked) do n = n + 1 end
        return n
    end)())
    return true
end

function tests.sourcedata_purge_falls_back_to_empty_map()
    local files = {}
    local sd = SourceData.new{ storage = {
        load = function(k) return files[k] or {} end,
        save = function(k, m) files[k] = m or {} return true end,
    } }
    assert_eq("无 delete 时按 save 成功", true, sd:purge("a"))
    assert_eq("内容已清空", 0, (function()
        local n = 0
        for _ in pairs(files.a) do n = n + 1 end
        return n
    end)())
    return true
end

-- ---- ADR-005：本文件与 browser/main 的删除段都不能出现 hold_* ----
-- 与 CI 的 scripts/check_no_hold.py 同规则：注释里允许提（那里正是解释
-- 为什么不用长按的地方），代码行不允许。

--- 粗粒度去注释：整行 `--` 开头与行尾 `-- …`（本项目无字符串内 `--`）。
local function stripComments(src)
    local out = {}
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*%-%-") then
            out[#out + 1] = line:gsub("%s%-%-.*$", "")
        else
            out[#out + 1] = ""
        end
    end
    return table.concat(out, "\n")
end

local function readModule(name)
    local f = assert(package.searchpath(name, package.path))
    return assert(io.open(f, "rb")):read("a")
end

function tests.no_hold_in_delete_code()
    local src = stripComments(readModule("browser"))
    local seg = src:match("(function Browser:showSourceMultiDelete.-\nend)\n")
    assert(seg, "批量删除函数体取不到")
    assert_eq("无 hold_*", nil, seg:match("hold_%a"))
    local main = stripComments(readModule("main"))
    assert(main:find("showSourceMultiDelete", 1, true), "菜单没接批量删除")
    assert_eq("main 代码行无 hold_*", nil, main:match("hold_%a"))
    return true
end

return tests
