-- unit test: browser.lua 的发现(explore)分支
-- 背景（2026-09-24 移植包真机实测）：31 个移植源全部只声明 explore、没有
-- category，主页只剩「搜索」；且 explore 项要按数组下标取（explore.0.load），
-- 旧的成员链拼成 `s?.explore?.0?.load` 是 JS 语法错。这里把三条都钉住。

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

package.loaded["browser"] = nil
local Browser = require("browser")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

--- 成员路径拼装：数字段必须走 ?.[n]，普通段走 ?.name
local tests = {}

function tests.member_chain_names_and_indices()
    assert_eq("single", "s?.category", Browser.memberChain("category"))
    assert_eq("nested", "s?.comic?.loadInfo", Browser.memberChain("comic.loadInfo"))
    assert_eq("index", "s?.explore?.[0]?.load",
        Browser.memberChain("explore.0.load"))
    assert_eq("index in middle",
        "s?.explore?.[3]?.subExplores?.[1]?.load",
        Browser.memberChain("explore.3.subExplores.1.load"))
    return true
end

-- 声明表：路径 → 返回值（nil = 该成员不存在，err 里带 "missing"）
-- registered = false → 该源没进引擎（_ensureSourceLoaded 失败）；否则
-- 任何 key 都当作已注册，主页流程才会往下走。
local function makeB(decls, opts)
    opts = opts or {}
    local b = setmetatable({}, { __index = Browser })
    b.engine = { eval = noop }
    if opts.registered == false then
        b._registered = {}
        b.sources = nil
    else
        b._registered = setmetatable({}, { __index = function() return "jsk" end })
    end
    b.messages = {}
    b.infoMessage = function(text) table.insert(b.messages, text) end
    b.calls = {}
    b._awaitSource = function(_, _key, path, argsJson)
        table.insert(b.calls, { path = path, args = argsJson })
        local v = decls[path]
        if v == nil then return nil, "missing " .. path end
        return v
    end
    return b
end

local function lastMenu()
    for i = #fake.shown, 1, -1 do
        local w = fake.shown[i]
        if type(w) == "table" and w.__menu then return w.args end
    end
end

local function texts(item_table)
    local o = {}
    for _, it in ipairs(item_table or {}) do o[#o + 1] = it.text end
    return table.concat(o, "|")
end

-- ---- 主页：只有 explore 的源（移植包的真实形状） ----

local CZ_BUNDLE = {
    category = nil,
    explore = {
        { title = "最新上架", type = "multiPageComicList" },
        { title = "中国", type = "multiPageComicList" },
        { title = "耽美", type = "multiPageComicList" },
    },
}

function tests.explore_only_source_lists_its_items()
    fake.shown = {}
    local b = makeB(CZ_BUNDLE)
    b:showSourceHome("czmanga")
    local m = lastMenu()
    assert(m, "菜单必须显示")
    assert_eq("搜索 + 3 个发现项", "搜索|最新上架|中国|耽美", texts(m.item_table))
    local it = m.item_table[2]
    assert_eq("路径按下标", "explore.1.load", it.explore_path)
    assert_eq("type 透传", "multiPageComicList", it.explore_type)
    assert_eq("注册失败提示不该出现", 0, #b.messages)
    return true
end

function tests.category_source_still_works_and_no_explore_hint()
    fake.shown = {}
    local b = makeB({
        category = { parts = { { name = "主题",
                                 categories = { "热血", "恋爱" },
                                 categoryParams = { "1", "2" } } } },
        explore = nil,
    })
    b:showSourceHome("copymanga2")
    local m = lastMenu()
    assert_eq("分类照旧", "搜索|主题|热血|恋爱", texts(m.item_table))
    assert_eq("无多余提示", 0, #b.messages)
    return true
end

-- v1.0.1 移植包把 categories 写成了 {label,target:{page,attributes}} 对象数组。
-- 必须按 label 显示，并把 attributes.param（URL 模板）作为分类实参传进
-- categoryComics.load；否则界面上是 "table: 0x…"，点进去 URL 退化成 baseUrl。
function tests.category_object_entries_map_label_and_param()
    fake.shown = {}
    local b = makeB({
        category = { parts = { { name = "发现", type = "fixed", categories = {
            { label = "漫画", target = { page = "category", attributes = {
                category = "漫画", param = "https://x.com/index-{page}.html" } } },
            { label = "图集", target = { page = "category", attributes = {
                category = "图集", param = "https://x.com/hentai-{page}" } } },
        } } } },
    })
    b:showSourceHome("acg2")
    local m = lastMenu()
    assert_eq("按 label 显示", "搜索|发现|漫画|图集", texts(m.item_table))
    local row = m.item_table[3]
    assert_eq("分类值取 attributes.category", "漫画", row.category)
    assert_eq("param 取 target.attributes.param",
        "https://x.com/index-{page}.html", row.param)
    local called
    b.showResults = function(_, key, methodPath, argsTable, page, title)
        called = { key = key, method = methodPath, args = argsTable,
                   page = page, title = title }
    end
    b:_openCategoryItem({ key = "acg2", category = row.category,
        param = row.param, text = row.text })
    assert_eq("走 categoryComics.load", "categoryComics.load", called.method)
    assert_eq("第一页", 1, called.page)
    assert_eq("标题是 label", "漫画", called.title)
    assert_eq("实参 1 = category", "漫画", called.args[1])
    assert_eq("实参 2 = param", "https://x.com/index-{page}.html", called.args[2])
    return true
end

-- 两者都没声明：必须给可见说明（用户反馈"点进去什么都没有"）
function tests.source_with_nothing_declared_shows_hint()
    fake.shown = {}
    local b = makeB({})
    b:showSourceHome("mystery")
    local m = lastMenu()
    assert_eq("只有搜索 + 说明行", 2, #(m.item_table))
    assert_eq("说明行是灰行", true, m.item_table[2].info_only)
    return true
end

-- 源根本注册不进去（移植包 21/31 是 JS 语法错）：说清是"源无法加载"，
-- 而不是把 SyntaxError 冒充"分类声明读取失败"
function tests.unregistered_source_reports_load_failure_once()
    fake.shown = {}
    local b = makeB({}, { registered = false })
    b:showSourceHome("broken")
    assert_eq("一条提示", 1, #b.messages)
    assert(b.messages[1]:find("无法加载", 1, true), "文案要点：无法加载")
    assert_eq("不再开空菜单", nil, lastMenu())
    return true
end

-- ---- 下钻：分页型直接复用 showResults ----

function tests.multipage_explore_reuses_showResults()
    local b = makeB(CZ_BUNDLE)
    local seen
    b.showResults = function(_, _k, path, args, page, title)
        seen = { path = path, args = args, page = page, title = title }
    end
    b:_openExploreItem("czmanga", {
        text = "中国", explore_path = "explore.2.load",
        explore_type = "multiPageComicList",
    })
    assert_eq("path", "explore.2.load", seen.path)
    assert_eq("page 从 1 起", 1, seen.page)
    assert_eq("无前置参数", 0, #seen.args)
    assert_eq("标题", "中国", seen.title)
    return true
end

-- ---- 分区型（copy_manga singlePageWithMultiPart）→ 分区子菜单 ----

function tests.multipart_explore_builds_parts_menu()
    fake.shown = {}
    local b = makeB({ ["explore.1.load"] = {
        ["最新更新"] = { { id = "a", title = "甲" }, { id = "b", title = "乙" } },
        ["热门"] = { { id = "c", title = "丙" } },
    } })
    b:_openExploreItem("copymanga2", {
        text = "拷贝漫画", explore_path = "explore.1.load",
        explore_type = "singlePageWithMultiPart",
    })
    local m = lastMenu()
    assert_eq("两个分区（标题排序稳定）", "最新更新|热门", texts(m.item_table))
    assert_eq("分区带条数", "2", m.item_table[1].mandatory)
    return true
end

-- pageCol：{ pages = [{title, comics}] }
function tests.pagecol_explore_flattens_pages()
    fake.shown = {}
    local b = makeB({ ["explore.1.load"] = { pages = {
        { title = "本周", comics = { { id = "1", title = "一" } } },
    } } })
    b:_openExploreItem("x", { text = "周榜", explore_path = "explore.1.load",
                             explore_type = "pageCol" })
    local m = lastMenu()
    -- 单分区 → 直接出漫画列表（标题后缀是数量）
    assert_eq("单页直达漫画列表（面包屑前缀，§10 O4）", "x › 周榜 · 1", m.title)
    assert_eq("漫画项", "一", m.item_table[1].text)
    return true
end

-- 未知类型 + 返回纯数组：兜底成一部列表
function tests.unknown_type_array_falls_back_to_list()
    fake.shown = {}
    local b = makeB({ ["explore.1.load"] = { { id = "1", title = "一" },
                                             { id = "2", title = "二" } } })
    b:_openExploreItem("x", { text = "怪型", explore_path = "explore.1.load",
                             explore_type = "whatever" })
    local m = lastMenu()
    assert_eq("2 部（面包屑前缀，§10 O4）", "x › 怪型 · 2", m.title)
    assert_eq("首项", "一", m.item_table[1].text)
    return true
end

-- ---- subExplores：二级菜单路径要带上下标前缀 ----

function tests.subexplores_build_nested_paths()
    fake.shown = {}
    -- 每一层都是独立一次 eval（子项数组按成员路径单独取），所以两级都要声明
    local subs = {
        { title = "日本", type = "multiPageComicList" },
        { title = "欧美", type = "comicList" },
    }
    local b = makeB({
        explore = { { title = "地区", subExplores = subs } },
        ["explore.1.subExplores"] = subs,
    })
    b:showSourceHome("y")
    local m = lastMenu()
    assert_eq("主页只有搜索+分组", "搜索|地区", texts(m.item_table))
    assert_eq("子项路径", "explore.1.subExplores", m.item_table[2].explore_sub)
    -- 点开分组 → 子菜单项路径带两级下标
    b:_openExploreItem("y", m.item_table[2])
    local sub = lastMenu()
    assert_eq("子菜单", "日本|欧美", texts(sub.item_table))
    assert_eq("子项 1 路径", "explore.1.subExplores.1.load",
        sub.item_table[1].explore_path)
    assert_eq("子项 2 类型", "comicList", sub.item_table[2].explore_type)
    return true
end

-- ---- showResults：数组返回值 / 空数据的形状兼容 ----

local function comicRow(id, title) return { id = id, title = title } end

function tests.showResults_accepts_bare_array()
    fake.shown = {}
    local b = makeB({ ["explore.1.load"] = { comicRow("1", "甲"),
                                             comicRow("2", "乙") } })
    b.progressMessage = noop
    b:showResults("z", "explore.1.load", {}, 1, "列表")
    local m = lastMenu()
    assert_eq("数组即 comics", "甲|乙", texts(m.item_table))
    assert_eq("无 maxPage 就不给下一页", nil, m.item_table[3])
    return true
end

function tests.showResults_wrapped_object_still_paginates()
    fake.shown = {}
    local b = makeB({ ["explore.1.load"] = { maxPage = 7,
        comics = { comicRow("1", "甲") } } })
    b.progressMessage = noop
    b:showResults("z", "explore.1.load", {}, 2, "列表")
    local m = lastMenu()
    assert_eq("下一页在末尾", "▶ 下一页", m.item_table[2].text)
    assert(m.title:find("2/7", 1, true), "标题要有 当前/总页：" .. tostring(m.title))
    return true
end

-- 源返回非表（null/字符串）时不得在 lightuserdata 上索引 → 主循环闪退
function tests.showResults_rejects_non_table_payload()
    fake.shown = {}
    local b = makeB({})
    b._awaitSource = function() return "ok" end
    b.progressMessage = noop
    b:showResults("z", "explore.1.load", {}, 1, "列表")
    assert_eq("只提示不出菜单", 1, #b.messages)
    assert_eq("没有菜单", nil, lastMenu())
    return true
end

-- 失败文案要能指导下一步：站点不通 / 站点活着但规则没落地 / 需要登录，
-- 三类各给各的指引，且不能互相叠加（原文是 wantread、"解析到 0 个条目"
-- 这种用户看不懂的字符串）
function tests.showResults_failure_hints_are_class_specific()
    local cases = {
        { "https(经代理) 请求失败: TLS 握手失败: wantread", "站点没有响应" },
        { "解析到 0 个条目: https://v4api.x.com/list/0/1", "选择器缺失" },
        { "Error: Not logged in", "账号登录" },
        { "HTTP 500 @ https://x.com/a", nil },
    }
    for _, c in ipairs(cases) do
        fake.shown = {}
        local b = makeB({})
        b._awaitSource = function() return nil, c[1] end
        b.progressMessage = noop
        b:showResults("z", "categoryComics.load", { "a" }, 1, "列表")
        local msg = b.messages[1] or ""
        assert(msg:find("加载失败", 1, true), "原文要在提示里: " .. msg)
        if c[2] then
            assert(msg:find(c[2], 1, true),
                c[1] .. " → 提示里应有「" .. c[2] .. "」，实际: " .. msg)
        end
        -- 只允许出现一类指引
        local n = 0
        for _, pat in ipairs({ "站点没有响应", "选择器缺失", "账号登录" }) do
            if msg:find(pat, 1, true) then n = n + 1 end
        end
        assert_eq(c[1] .. " 指引条数", c[2] and 1 or 0, n)
    end
    return true
end

--- 盖栈导航契约（审查报告 §10 O1/O2，2026-09-24）：
--- 源列表 → 源主页 不再先关列表（O2），且新菜单带返回箭头（O1）。
function tests.source_list_to_home_keeps_stack()
    fake.shown, fake.closed = {}, {}
    local b = setmetatable({}, { __index = Browser })
    b.messages = {}
    b.infoMessage = function(text) table.insert(b.messages, text) end
    b.engine = { eval = function() end }
    b._guard = function(_, _label, fn) fn() end
    b.sources = { listInstalled = function()
        return { { key = "x", name = "测试源", version = "1.0.0" } }
    end, uniqueLabels = function(list)
        local o = {}
        for i, e in ipairs(list) do o[i] = e.name or e.key end
        return o
    end }
    b._ensureSourceLoaded = function() return "jsk" end
    b._awaitSource = function(_, _k, path)
        if path == "category" then
            return { parts = {} }
        end
        return nil, "stub"
    end
    b:showSourceList()
    assert_eq("源列表已显示", 1, #fake.shown)
    local list_menu = fake.shown[1]
    assert_eq("O1: 返回箭头已配置", "chevron.left",
        list_menu.args.title_bar_left_icon)
    -- 点第一个源：主页压上来，列表不关（closed == 0）
    list_menu.args.onMenuSelect(list_menu, { key = "x", name = "测试源" })
    assert_eq("O2: 进入源主页不拆栈", 0, #fake.closed)
    assert_eq("主页已压栈", 2, #fake.shown)
    local home = fake.shown[2].args
    assert_eq("O4: 主页面包屑为源名", "测试源", home.title)
    -- 主页左键 = 关自己（返回源列表），不波及列表
    home.onLeftButtonTap(home)
    assert_eq("左键只关当前层", 1, #fake.closed)
    return true
end

return tests
