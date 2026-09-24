-- unit test: runtime/sourcedata.lua —— 源参数与登录态的落盘层
-- 语义来源（上游 EZVenera）：
--   load_setting → data['settings'][key] ?? 源声明 default
--                  （lib/src/plugin_runtime/engine/plugin_js_engine.dart）
--   isLogged     → _ez_logged==true || account!=null || _localStorage 非空
--                  （lib/src/plugin_runtime/models.dart:112）
--   登录成功      → 由**宿主**写 _ez_logged：多数源只 saveData('token')

local SourceData = require("runtime/sourcedata")
local Bridge = require("runtime.bridge")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
end

--- 深拷贝的内存后端：load 不把内部表交出去，否则"改了内存对象就算落盘"
--- 这类错误测不出来（真机表现：界面写完参数，桥那边还是旧的）。
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

local tests = {}

function tests.written_setting_is_visible_to_the_bridge()
    local _, store = memStore()
    local sd = SourceData.new{ storage = store }
    local b = Bridge.new{ storage = store }
    sd:setSetting("picacg", "base_url", "https://pica.example.com")
    assert_eq("桥侧 load_setting 读到界面写的值", "https://pica.example.com",
        b:handle({ method = "load_setting", key = "picacg",
                   setting_key = "base_url" }))
    return true
end

function tests.unset_setting_is_nil_not_empty_string()
    -- 必须回 nil：声明的 default 由 jshost 注册处包装的 loadSetting 补齐。
    -- 返回 "" 会把"没配过"和"用户填了空值"混成一件。
    local _, store = memStore()
    local b = Bridge.new{ storage = store }
    assert_eq("未设置为 nil", nil, b:handle({ method = "load_setting",
        key = "x", setting_key = "base_url" }))
    return true
end

function tests.settings_are_isolated_per_source_and_slot()
    local _, store = memStore()
    local sd = SourceData.new{ storage = store }
    sd:setSetting("picacg", "imageQuality", "low")
    assert_eq("另一源不受影响", nil, sd:getSetting("baozi", "imageQuality"))
    assert_eq("另一参数不受影响", nil, sd:getSetting("picacg", "appChannel"))
    return true
end

function tests.token_written_by_the_source_survives_setting_writes()
    -- save_data（桥）与 setSetting（界面）共用一个 JSON 文件，
    -- 任何一方都不能踩掉另一方的槽位
    local _, store = memStore()
    local sd = SourceData.new{ storage = store }
    local b = Bridge.new{ storage = store }
    b:handle({ method = "save_data", key = "picacg", data_key = "token",
               data = "abc123" })
    sd:setSetting("picacg", "appChannel", "3")
    assert_eq("token 仍在", "abc123",
        b:handle({ method = "load_data", key = "picacg",
                   data_key = "token" }))
    assert_eq("参数仍在", "3", sd:getSetting("picacg", "appChannel"))
    sd:clearSettings("picacg")
    assert_eq("恢复默认：参数清空", nil, sd:getSetting("picacg", "appChannel"))
    assert_eq("恢复默认：token 不动", "abc123",
        b:handle({ method = "load_data", key = "picacg",
                   data_key = "token" }))
    return true
end

function tests.setting_set_to_nil_falls_back_to_declared_default()
    local _, store = memStore()
    local sd = SourceData.new{ storage = store }
    sd:setSetting("s", "k", "custom")
    assert_eq("已存值", "custom", sd:getSetting("s", "k"))
    sd:setSetting("s", "k", nil)
    assert_eq("删除后回到未设置", nil, sd:getSetting("s", "k"))
    return true
end

function tests.isLogged_matches_upstream_rule()
    local cases = {
        { "空数据", {}, false },
        { "宿主标记为真", { _ez_logged = true }, true },
        { "标记为假但存了账号", { _ez_logged = false, account = { "u" } }, true },
        { "_localStorage 非空", { _localStorage = { sid = "1" } }, true },
        { "_localStorage 空表", { _localStorage = {} }, false },
        { "_localStorage 不是表", { _localStorage = "x" }, false },
        { "标记写成字符串", { _ez_logged = "true" }, false },
        -- 上游同规则：源自己 saveData('token') 不等于登录
        { "只有 token 不算登录", { token = "t" }, false },
    }
    for _, c in ipairs(cases) do
        assert_eq(c[1], c[3], SourceData.isLoggedMap(c[2]))
    end
    assert_eq("非表输入", false, SourceData.isLoggedMap(nil))
    return true
end

function tests.bridge_isLogged_uses_the_same_rule_as_the_ui()
    local _, store = memStore()
    local sd = SourceData.new{ storage = store }
    local b = Bridge.new{ storage = store }
    assert_eq("初始未登录", false,
        b:handle({ method = "isLogged", key = "picacg" }))
    sd:markLoggedIn("picacg")
    -- 真机回归点：源里的 `this.isLogged` 走桥，界面走 SourceData。
    -- 两边不同步的话，登录成功源照样抛 "Not logged in"。
    assert_eq("桥侧已登录", true,
        b:handle({ method = "isLogged", key = "picacg" }))
    assert_eq("界面已登录", true, sd:isLogged("picacg"))
    sd:markLoggedOut("picacg")
    assert_eq("注销后未登录", false,
        b:handle({ method = "isLogged", key = "picacg" }))
    return true
end

function tests.markLoggedOut_clears_credentials_but_keeps_other_slots()
    local files, store = memStore()
    local sd = SourceData.new{ storage = store }
    sd:markLoggedIn("s", { "user@example.com", "pw" })
    local map = files["s"]
    map._localStorage = { token = "t" }
    map.bookmark_cache = "x"
    store.save("s", map)
    sd:markLoggedOut("s")
    map = files["s"]
    assert_eq("标记归假", false, map._ez_logged)
    assert_eq("账号清除", nil, map.account)
    assert_eq("localStorage 清除", nil, map._localStorage)
    assert_eq("无关槽位保留", "x", map.bookmark_cache)
    return true
end

function tests.clear_empties_the_whole_file()
    local _, store = memStore()
    local sd = SourceData.new{ storage = store }
    sd:setSetting("s", "k", "v")
    sd:markLoggedIn("s")
    assert_eq("清空返回真", true, sd:clear("s"))
    assert_eq("参数没了", nil, sd:getSetting("s", "k"))
    assert_eq("登录态没了", false, sd:isLogged("s"))
    return true
end

function tests.allSettings_tolerates_a_broken_file()
    -- 手工改坏过 settings 槽（非表）时界面不能崩
    local store = {
        load = function() return { settings = "坏数据" } end,
        save = function() return true end,
    }
    local sd = SourceData.new{ storage = store }
    assert_eq("退化成空表", 0, (function()
        local n = 0
        for _ in pairs(sd:allSettings("s")) do n = n + 1 end
        return n
    end)())
    return true
end

return tests
