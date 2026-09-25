-- unit test: runtime/jshost.lua 的 ESM 剥壳（normalizeSourceJs）
-- 背景：registerSource 把整段源塞进 (()=>{ … })() 用 JS_Eval(GLOBAL) 求值，
-- 而 import/export 在函数体内是硬 SyntaxError。上游 EZvenera-config 的 .js
-- 没有 export，但移植流水线/社区源普遍带 `export default XxxSource;` 尾行，
-- 一份 31 源的移植包实测 31/31 因此注册失败（2026-09-24 核查）。
-- 这里覆盖四种 ESM 形态 + 「无 export 必须逐字节原样返回」这条红线。
local JsHost = require("runtime.jshost")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function assert_true(label, v)
    assert(v == true, label .. ": expected true, got " .. tostring(v))
end

local tests = {}

local ESM_TAIL = [[
/* 生成头注释
 * 说明: class 这个词出现在注释里不算
 */
class Acg2Source extends ComicSource {
    name = "ACG漫画网";
    key = "acg2";
    getPopular = async (page) => { return []; };
}
export default Acg2Source;
]]

function tests.strip_tail_export_default_and_finds_class()
    local script, classname = JsHost.normalizeSourceJs(ESM_TAIL)
    assert_true("解析成功", script ~= nil)
    assert_eq("类名", "Acg2Source", classname)
    assert_true("export 已剥掉", not script:find("export"))
    -- 注释里的 `class` 字样不能把行扫描带偏，正文必须完整保留
    assert_true("正文保留", script:find("getPopular = async", 1, true) ~= nil)
    assert_true("头注释保留", script:find("生成头注释", 1, true) ~= nil)
    return true
end

function tests.strip_inline_export_default_class()
    local src = "export default class BaoziSource extends ComicSource {\n  key = \"baozi\";\n}\n"
    local script, classname = JsHost.normalizeSourceJs(src)
    assert_true("解析成功", script ~= nil)
    assert_eq("类名", "BaoziSource", classname)
    assert_eq("行首变成 class", "class BaoziSource", script:match("^class [%w_]+"))
    assert_true("无残留关键字", not script:find("export"))
    return true
end

function tests.strip_named_export_and_static_imports()
    local src = table.concat({
        "import helper from './_venera_.js';",
        "import { a, b } from \"mod.js\";",
        "class FooSource extends ComicSource {}",
        "export { FooSource };",
        "export default FooSource",   -- 末尾无分号、无换行
    }, "\n")
    local script, classname = JsHost.normalizeSourceJs(src)
    assert_true("解析成功", script ~= nil)
    assert_eq("类名", "FooSource", classname)
    assert_true("无 export", not script:find("export"))
    assert_true("无 import", not script:find("import"))
    return true
end

-- 红线：没动过就必须一个字节都不差（老源的 sha256/体积指纹依赖这一点）
function tests.no_esm_returns_bytes_identical()
    local src = "class CopyManga extends ComicSource {\r\n  key = \"copy_manga\";\r\n}\r\n"
    local script = JsHost.normalizeSourceJs(src)
    assert_eq("逐字节相同", src, script)
    return true
end

-- 注释/字符串里的 "export default" 不是包装行，不许误删
function tests.export_inside_comment_or_string_is_kept()
    local src = table.concat({
        "class FooSource extends ComicSource {",
        "  // export default FooSource;",
        "  doc = \"export default FooSource;\";",
        "}",
    }, "\n")
    local script, classname = JsHost.normalizeSourceJs(src)
    assert_eq("类名", "FooSource", classname)
    assert_true("注释行保留", script:find("// export default FooSource;", 1, true) ~= nil)
    assert_true("字符串保留", script:find("\"export default FooSource;\"", 1, true) ~= nil)
    return true
end

function tests.rejects_non_comicsource_first_class()
    local src = "class Helper extends Thing {}\nclass FooSource extends ComicSource {}\n"
    local script, err = JsHost.normalizeSourceJs(src)
    assert_true("拒绝", script == nil)
    assert_true("报 missing ComicSource class", tostring(err):find("missing ComicSource") ~= nil)
    return true
end

function tests.rejects_empty_and_non_string()
    local s1, e1 = JsHost.normalizeSourceJs("")
    assert_true("空串拒绝", s1 == nil)
    assert_eq("错误信息", "empty source", e1)
    local s2, e2 = JsHost.normalizeSourceJs(nil)
    assert_true("nil 拒绝", s2 == nil)
    assert_eq("错误信息", "empty source", e2)
    return true
end

function tests.esm_tail_with_crlf_still_loads()
    local src = (ESM_TAIL:gsub("\n", "\r\n"))
    local script, classname = JsHost.normalizeSourceJs(src)
    assert_true("解析成功", script ~= nil)
    assert_eq("类名", "Acg2Source", classname)
    assert_true("CRLF 已归一", not script:find("\r", 1, true))
    return true
end

return tests
