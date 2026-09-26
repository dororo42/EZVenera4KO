-- unit test: browser.lua 的源参数配置 / 登录界面逻辑
-- 真机背景：安装 picacg 后浏览报 "Not logged in"，而插件里既没有参数界面
-- 也没有登录入口 —— 该源的分类/搜索/章节都要求先登录拿 token。
-- browser.lua 顶层 require KOReader 前端模块，测试环境没有 → preload 桩。

local SourceData = require("runtime.sourcedata")

local noop = function() end
local captured_menu, captured_confirm
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end
stub("logger", { warn = noop, info = noop, err = noop, dbg = noop,
    verbose = noop })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", { show = noop, close = noop, scheduleIn = noop })
-- Menu/ConfirmBox 记下参数并原样返回，测试才能点行、确认
stub("ui/widget/menu", {
    new = function(_, o) captured_menu = o return o end,
})
stub("ui/widget/confirmbox", {
    new = function(_, o) captured_confirm = o return o end,
})
stub("ui/widget/infomessage", { new = noop })
package.loaded["browser"] = nil      -- 用本文件的桩重新加载
local Browser = require("browser")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
end

local function assert_true(label, cond)
    assert(cond, label)
end

local function assert_false(label, cond)
    assert(not cond, label)
end

--- 深拷贝后端：load 不交出内部表
local function memStore()
    local files = {}
    local function copy(v)
        if type(v) ~= "table" then return v end
        local o = {}
        for k, val in pairs(v) do o[k] = copy(val) end
        return o
    end
    return files, {
        load = function(key) return copy(files[key] or {}) end,
        save = function(key, map) files[key] = copy(map or {}); return true end,
    }
end

--- picacg 的真实声明形状（jshost sourceInfo 的返回：值已 String() 化）
local PICACG_INFO = {
    settings = {
        { key = "base_url", title = "API地址(地址末尾不要添加斜杠)",
          type = "input", def = "https://picaapi.picacomic.com" },
        { key = "imageQuality", title = "Image quality", type = "select",
          def = "original",
          options = { { value = "original", text = "original" },
                      { value = "medium", text = "medium" },
                      { value = "low", text = "low" } } },
    },
    account = { login = true, logout = true, website = nil },
}

--- 只带数据层的 Browser 替身（UI 就地打桩）
local function fakeBrowser(store, info)
    local b = setmetatable({}, { __index = Browser })
    b.sourcedata = SourceData.new{ storage = store }
    b.messages = {}
    -- 注意：browser.lua 用 **点号** 调 infoMessage（o.infoMessage = fn，
    -- 不是方法），所以替身的第一个参数就是文本本身。
    b.infoMessage = function(text)
        table.insert(b.messages, text)
    end
    b.progressMessage = noop
    b.engine = {
        sourceInfo = function() return info end,
        json = { encode = function(v)
            return '"' .. tostring(v):gsub('"', '\\"') .. '"'
        end },
    }
    b._ensureSourceLoaded = function() return "picacg" end
    return b
end

--- 打开源菜单，取第一个满足条件的行
local function sourceRow(b, predicate)
    b:showSourceMenu("picacg", "Picacg", "1.0.5")
    for _, row in ipairs(captured_menu.item_table) do
        if predicate(row) then return row end
    end
end

local tests = {}

-- ---------- 参数列表 ----------

function tests.rows_show_stored_value_or_declared_default()
    local b = fakeBrowser(select(2, memStore()))
    local rows = b:_settingRows(PICACG_INFO, { imageQuality = "low" })
    assert_eq("两行", 2, #rows)
    assert_eq("未设置显示默认", "https://picaapi.picacomic.com",
        rows[1].mandatory)
    assert_eq("已设置显示存值", "low", rows[2].mandatory)
    assert_eq("行携带声明供编辑器用", "input", rows[1].setting.type)
    return true
end

function tests.rows_render_booleans_in_chinese()
    local b = fakeBrowser(select(2, memStore()))
    local info = { settings = {
        { key = "a", title = "A", type = "switch", def = false },
        { key = "b", title = "B", type = "switch", def = true },
    } }
    local rows = b:_settingRows(info, { a = true })
    assert_eq("存值覆盖默认", "开", rows[1].mandatory)
    assert_eq("未设置时用声明默认", "开", rows[2].mandatory)
    return true
end

function tests.settings_menu_lists_the_source_and_a_reset_row()
    local b = fakeBrowser(select(2, memStore()), PICACG_INFO)
    b:showSourceSettings("picacg")
    assert_eq("标题", "源参数配置", captured_menu.title)
    local rows = captured_menu.item_table
    assert_eq("声明 2 项 + 恢复默认", 3, #rows)
    assert_true("末行是恢复默认", rows[3].reset_row)
    return true
end

function tests.reset_row_only_clears_the_settings_slot()
    local files, store = memStore()
    local b = fakeBrowser(store, PICACG_INFO)
    b.sourcedata:setSetting("picacg", "imageQuality", "low")
    files.picacg.token = "keep-me"       -- 模拟源自己 saveData('token')
    b:showSourceSettings("picacg")
    local rows = captured_menu.item_table
    captured_menu.onMenuSelect({}, rows[#rows])
    assert_eq("参数槽整体移除（回到源声明默认）", nil, files.picacg.settings)
    assert_eq("token 保留", "keep-me", files.picacg.token)
    return true
end

function tests.switch_row_toggles_and_repaints_the_list()
    local files, store = memStore()
    local b = fakeBrowser(store)
    local decl = { key = "nsfw", title = "NSFW", type = "switch", def = false }
    b:_editSetting("picacg", decl, false, noop)
    assert_eq("点一次变开", true, files.picacg.settings.nsfw)
    b:_editSetting("picacg", decl, true, noop)
    assert_eq("再点变关", false, files.picacg.settings.nsfw)
    return true
end

function tests.select_row_writes_the_picked_option()
    local files, store = memStore()
    local b = fakeBrowser(store)
    b:_editSetting("picacg", PICACG_INFO.settings[2], "original", noop)
    assert_eq("弹出的是选项菜单", "Image quality", captured_menu.title)
    assert_eq("三个选项", 3, #captured_menu.item_table)
    assert_true("当前值标星", captured_menu.item_table[1].marked)
    assert_false("未选的不标星", captured_menu.item_table[3].marked)
    captured_menu.onMenuSelect({}, captured_menu.item_table[3])
    assert_eq("写入所选", "low", files.picacg.settings.imageQuality)
    return true
end

function tests.input_row_trims_and_honours_the_validator()
    local files, store = memStore()
    local b = fakeBrowser(store)
    local decl = { key = "base_url", title = "API", type = "input",
        def = "", validator = "^https?://" }
    b._inputBox = function(_, _opts, onOk) onOk("  https://x  ", "DLG") end
    b.engine.testSettingValue = function() return false end
    b:_editSetting("picacg", decl, "", noop)
    assert_false("校验不过不落盘", files.picacg and files.picacg.settings)
    assert_eq("给了原因", 1, #b.messages)

    b.engine.testSettingValue = function() return true end
    local repainted = 0
    b:_editSetting("picacg", decl, "", function() repainted = repainted + 1 end)
    assert_eq("去空白后落盘", "https://x", files.picacg.settings.base_url)
    assert_eq("写完回列表刷新", 1, repainted)
    return true
end

function tests.input_row_saves_when_the_source_declares_no_validator()
    local files, store = memStore()
    local b = fakeBrowser(store)
    b._inputBox = function(_, _opts, onOk) onOk("abc", "DLG") end
    b.engine.testSettingValue = function()
        error("没有 validator 时不该去问引擎")
    end
    b:_editSetting("picacg",
        { key = "k", title = "K", type = "input", def = "" }, "", noop)
    assert_eq("直接落盘", "abc", files.picacg.settings.k)
    return true
end

function tests.input_box_degrades_without_the_dialog_widget()
    local b = fakeBrowser(select(2, memStore()))
    package.preload["ui/widget/inputdialog"] = nil
    package.loaded["ui/widget/inputdialog"] = nil
    b:_inputBox({ title = "T" }, noop)
    assert_eq("提示而非崩溃", 1, #b.messages)
    assert_true("文案说明为什么没弹框",
        b.messages[1]:find("KOReader", 1, true))
    return true
end

function tests.input_box_swallows_editor_errors()
    -- onOk 里抛错必须被收住：这是 KOReader widget 直接调用的入口（R9 崩溃链）
    local b = fakeBrowser(select(2, memStore()))
    local shown
    -- 自带桩，不依赖别的测试留下的环境（用例顺序不保证）
    package.preload["ui/widget/inputdialog"] = function()
        return { new = function(_, o)
            shown = o
            return { getInputText = function() return "x" end,
                     onShowKeyboard = noop }
        end }
    end
    package.loaded["ui/widget/inputdialog"] = nil
    b:_inputBox({ title = "T" }, function() error("boom") end)
    assert_true("拿到确认按钮", shown and shown.buttons
        and shown.buttons[1][2].callback)
    local ok = pcall(shown.buttons[1][2].callback)
    assert_true("回调不外抛", ok)
    package.preload["ui/widget/inputdialog"] = nil
    package.loaded["ui/widget/inputdialog"] = nil
    return true
end

-- ---------- 登录 / 注销 ----------

function tests.login_dialog_asks_account_then_masked_password()
    local b = fakeBrowser(select(2, memStore()))
    local dialogs = {}
    b._inputBox = function(_, opts, onOk)
        table.insert(dialogs, opts)
        if #dialogs == 1 then onOk("  u@x.com  ", "D1")
        elseif #dialogs == 2 then onOk("p@ss word", "D2") end
    end
    local sent
    b._doLogin = function(_, _key, _jsKey, user, pwd)
        sent = { user = user, pwd = pwd }
    end
    b:showLoginDialog("picacg")
    assert_eq("两步输入", 2, #dialogs)
    assert_true("第二步遮罩", dialogs[2].password)
    assert_false("第一步不遮罩", dialogs[1].password)
    assert_eq("账号去空白", "u@x.com", sent.user)
    assert_eq("口令原样传（上游同规则）", "p@ss word", sent.pwd)
    return true
end

function tests.login_dialog_rejects_an_empty_account()
    local b = fakeBrowser(select(2, memStore()))
    local asked = 0
    b._inputBox = function(_, _opts, onOk)
        asked = asked + 1
        onOk("   ", "D1")
    end
    b:showLoginDialog("picacg")
    assert_eq("只问了账号", 1, asked)
    assert_true("空账号给出指引",
        b.messages[1]:find("账号不能为空", 1, true))
    return true
end

function tests.login_calls_the_source_then_marks_logged_in()
    local files, store = memStore()
    local b = fakeBrowser(store)
    b._awaitSource = function(_, key, path, argsJson)
        b.called = { key = key, path = path, args = argsJson }
        return "ok"
    end
    b:_doLogin("picacg", "picacg", "u@x.com", 'p"w"1')
    assert_eq("用清单 key 调源", "picacg", b.called.key)
    assert_eq("调的是 account.login", "account.login", b.called.path)
    assert_eq("参数是 JSON 数组且转义引号", '["u@x.com","p\\"w\\"1"]',
        b.called.args)
    assert_eq("宿主打上登录标记", true, files.picacg._ez_logged)
    assert_eq("口令不落盘（数据目录在 /sdcard 共享存储）", nil,
        files.picacg.account)
    assert_eq("桥现在同样回答已登录", true, b.sourcedata:isLogged("picacg"))
    return true
end

function tests.login_failure_leaves_the_state_untouched()
    local files, store = memStore()
    local b = fakeBrowser(store)
    b._awaitSource = function() return nil, "Failed to login" end
    b:_doLogin("picacg", "picacg", "u", "p")
    assert_false("未写文件", files.picacg)
    assert_eq("弹窗带源抛出的原因", 1, #b.messages)
    assert_true("原因原文可见", b.messages[1]:find("Failed to login", 1, true))
    return true
end

function tests.logout_marks_out_before_running_the_sources_logout()
    local files, store = memStore()
    local b = fakeBrowser(store)
    b.sourcedata:markLoggedIn("picacg", { "u", "p" })
    local seen = {}
    b._awaitSource = function()
        -- 上游顺序：先 markLoggedOut 再 account.logout（models.dart:996）
        seen.logged_when_called = b.sourcedata:isLogged("picacg")
        seen.path = "account.logout"
        return nil
    end
    b:_confirmLogout("picacg", "picacg")
    assert_true("先要确认", captured_confirm.ok_callback ~= nil)
    captured_confirm.ok_callback()
    assert_eq("调了源的 logout", "account.logout", seen.path)
    assert_false("调源时宿主标记已清", seen.logged_when_called)
    assert_eq("文件里标记为假", false, files.picacg._ez_logged)
    assert_eq("账号已清", nil, files.picacg.account)
    return true
end

-- ---------- 源菜单 ----------

function tests.source_menu_offers_everything_the_source_supports()
    local b = fakeBrowser(select(2, memStore()), PICACG_INFO)
    assert_true("有登录项", sourceRow(b, function(r) return r.login_row end))
    assert_true("有注销项", sourceRow(b, function(r) return r.logout_row end))
    assert_true("有参数配置项",
        sourceRow(b, function(r) return r.settings_row end))
    assert_true("有清除数据项", sourceRow(b, function(r) return r.clear_row end))
    assert_true("有删除项", sourceRow(b, function(r) return r.remove_row end))
    assert_eq("未登录显示", "未登录",
        sourceRow(b, function(r) return r.info_row end).mandatory)
    return true
end

function tests.source_menu_hides_login_for_anonymous_sources()
    local b = fakeBrowser(select(2, memStore()),
        { settings = {}, account = { login = false, logout = true } })
    assert_false("无 login 能力就不给登录项",
        sourceRow(b, function(r) return r.login_row end))
    assert_true("仍可读参数",
        sourceRow(b, function(r) return r.settings_row end))
    return true
end

function tests.source_menu_shows_a_register_site_when_only_that_exists()
    -- picacg 只声明 registerWebsite（manhuabika.com/pregister）
    local b = fakeBrowser(select(2, memStore()), { settings = {},
        account = { login = true, logout = true, register =
            "https://manhuabika.com/pregister/?" } })
    local row = sourceRow(b, function(r) return r.url end)
    assert_eq("给出注册地址", "https://manhuabika.com/pregister/?", row.url)
    return true
end

function tests.source_menu_settings_row_routes_to_the_config_screen()
    local b = fakeBrowser(select(2, memStore()), PICACG_INFO)
    local went = 0
    b.showSourceSettings = function() went = went + 1 end
    local row = sourceRow(b, function(r) return r.settings_row end)
    captured_menu.onMenuSelect({}, row)
    assert_eq("转到参数配置", 1, went)
    return true
end

function tests.source_menu_reports_logged_in_after_login()
    local _, store = memStore()
    local b = fakeBrowser(store, PICACG_INFO)
    b.sourcedata:markLoggedIn("picacg")
    assert_eq("已登录", "已登录",
        sourceRow(b, function(r) return r.info_row end).mandatory)
    return true
end

function tests.source_menu_still_works_without_the_engine()
    local b = fakeBrowser(select(2, memStore()), PICACG_INFO)
    b._ensureSourceLoaded = function() return nil, "引擎不可用" end
    b.engine = nil
    b:showSourceMenu("picacg", "Picacg", "1.0.5")
    assert_true("标题仍有源名",
        captured_menu.title:find("Picacg", 1, true))
    assert_false("引擎不在就没有清除数据项（数据也读不到）",
        sourceRow(b, function(r) return r.clear_row end))
    assert_true("删除源仍可用（纯文件操作）",
        sourceRow(b, function(r) return r.remove_row end))
    assert_eq("登录态显示为未知", "",
        sourceRow(b, function(r) return r.info_row end).mandatory)
    return true
end

function tests.removing_a_source_deletes_files_and_invalidates()
    local b = fakeBrowser(select(2, memStore()), PICACG_INFO)
    local removed, invalidated = 0, 0
    b.sources = { remove = function() removed = removed + 1 return true end,
        -- 源菜单会查覆盖备份（没有就不显示「回退到旧版」行）
        listBackups = function() return {} end }
    b.invalidateSource = function() invalidated = invalidated + 1 end
    b:showSourceMenu("picacg", "Picacg", "1.0.5")
    captured_menu.onMenuSelect({},
        sourceRow(b, function(r) return r.remove_row end))
    assert_eq("先要确认，不直接删", 0, removed)
    captured_confirm.ok_callback()
    assert_eq("确认后删除", 1, removed)
    assert_eq("作废引擎注册", 1, invalidated)
    return true
end

-- ---------- 未登录指引（用户报的原始困惑） ----------

function tests.not_logged_in_errors_point_at_the_login_entry()
    local b = fakeBrowser(select(2, memStore()))
    b._awaitSource = function() return nil, "Not logged in" end
    b:showResults("picacg", "categoryComics.load", { "Random" }, 1, "R")
    assert_eq("一次弹窗", 1, #b.messages)
    assert_true("给出登录入口", b.messages[1]:find("账号登录", 1, true))
    assert_true("保留源的原文",
        b.messages[1]:find("Not logged in", 1, true))
    return true
end

function tests.other_errors_do_not_carry_the_login_hint()
    local b = fakeBrowser(select(2, memStore()))
    b._awaitSource = function() return nil, "Failed to fetch" end
    b:showResults("picacg", "categoryComics.load", { "Random" }, 1, "R")
    assert_eq("一次弹窗", 1, #b.messages)
    assert_false("无关错误不乱指引",
        b.messages[1]:find("账号登录", 1, true))
    return true
end

function tests.config_screen_explains_why_the_engine_is_required()
    local b = fakeBrowser(select(2, memStore()))
    b._ensureSourceLoaded = function()
        return nil, "引擎不可用（Android 引擎需随 APK 分发）"
    end
    b:showSourceSettings("picacg")
    assert_true("说清为什么打不开", b.messages[1]:find("引擎", 1, true))
    return true
end

function tests.ui_uses_plain_callbacks_only()
    -- ADR-005：配置入口只能普通点击（CI 有 check_no_hold.py，这里管界面侧）
    local f = assert(package.searchpath("browser", package.path))
    local src = assert(io.open(f, "rb")):read("a")
    assert_false("browser.lua 不得出现 hold_callback",
        src:find("hold_callback", 1, true))
    assert_false("browser.lua 不得出现 long_press",
        src:find("long_press", 1, true))
    return true
end

--- 真机回归：分类主页点灰行（分组标题）不该把菜单整层关掉
function tests.info_only_header_keeps_the_menu_open()
    local UIManager = require("ui/uimanager")
    local old_close = UIManager.close
    local closed = 0
    UIManager.close = function() closed = closed + 1 end
    local b = fakeBrowser(select(2, memStore()))
    b._awaitSource = function(_, _k, path)
        if path == "category" then
            return { parts = { { name = "主题", categories = { "大家都在看" },
                                 categoryParams = { "hot" } } } }
        end
    end
    b:showSourceHome("picacg")
    local header
    for _, r in ipairs(captured_menu.item_table) do
        if r.info_only then header = r end
    end
    assert_true("分组标题行有渲染", header)
    captured_menu.onMenuSelect({}, header)
    assert_eq("点标题行不关菜单", 0, closed)
    -- 盖栈导航（审查报告 §10 O2，2026-09-24）：真分类进入 = 调用
    -- showCategory 且**不再关闭本层**（下一层压上来，返回箭头可回）。
    -- 桩环境里 showCategory 会因 optionList 缺失提前返回，所以用 spy
    -- 断言「进入」，而非断言新菜单已渲染。
    local entered = 0
    local real_showCategory = b.showCategory
    b.showCategory = function(_, k, it)
        entered = entered + 1
        return real_showCategory(_, k, it)
    end
    captured_menu.onMenuSelect({}, { category = "大家都在看", key = "picacg" })
    assert_eq("真分类照常进入", 1, entered)
    assert_eq("进入不拆栈（本层保持打开）", 0, closed)
    UIManager.close = old_close
    return true
end

--- 真机回归：数据目录不可写时不能假装保存成功
function tests.unwritable_store_reports_failure()
    local info = { settings = {
        { key = "nsfw", title = "NSFW", type = "switch", def = false },
    } }
    local b = fakeBrowser({
        load = function() return {} end,
        save = function() return false end,
    }, info)
    b:showSourceSettings("picacg")
    captured_menu.onMenuSelect({}, captured_menu.item_table[1])
    local last = b.messages[#b.messages] or ""
    assert_true("要说清保存失败：" .. last, last:find("保存失败", 1, true))
    return true
end

return tests
