-- unit test: runtime/htmlparse.lua — HTML→DOM + CSS 选择器子集（M2 T15）
-- 契约锚点：reports/research/01 §2（Dart html 句柄语义）+ vendored init.js L654-995
local HtmlParse = require("runtime.htmlparse")

local tests = {}

local SAMPLE = [[
<html>
<head><title>T1</title><style>.a{color:red}</style></head>
<body>
<div id="main" class="container wide">
  <ul class="list">
    <li data-id="1" class="item first">Alpha</li>
    <li data-id="2" class="item">Beta</li>
    <li data-id="3" class="item last">Gamma</li>
  </ul>
  <a href="/next">Next</a>
  <img src="cover.jpg" alt="c">
  <br>
  <span>Text &amp; more</span>
</div>
<div class="footer">f</div>
</body>
</html>
]]

local function newDocEngine(html)
    local eng = HtmlParse.newEngine()
    eng:handle({ ["function"] = "parse", key = 1, data = html })
    return eng
end

local function assert_eq_count(label, expected, actual)
    assert(expected == actual, label .. ": expected " .. tostring(expected)
        .. " matches, got " .. tostring(actual))
end

function tests.parse_and_query_selector()
    local eng = newDocEngine(SAMPLE)
    local k = eng:handle({ ["function"] = "querySelector", key = 1,
        query = "#main" })
    assert(k, "querySelector #main should match")
    local tag = eng:handle({ ["function"] = "getLocalName", key = k, doc = 1 })
    assert(tag == "div", "expected div, got " .. tostring(tag))
    return true
end

function tests.query_selector_all_and_attrs()
    local eng = newDocEngine(SAMPLE)
    local ks = eng:handle({ ["function"] = "querySelectorAll", key = 1,
        query = "li.item" })
    assert(#ks == 3, "expected 3 li.item, got " .. tostring(#ks))
    local attrs = eng:handle({ ["function"] = "getAttributes",
        key = ks[2], doc = 1 })
    assert(attrs["data-id"] == "2", "data-id should be 2")
    return true
end

function tests.descendant_and_child_combinators()
    local eng = newDocEngine(SAMPLE)
    local a = eng:handle({ ["function"] = "querySelector", key = 1,
        query = "ul li" })
    assert(a, "descendant ul li should match")
    local b = eng:handle({ ["function"] = "querySelector", key = 1,
        query = "body > div" })
    assert(b, "child body > div should match")
    local c = eng:handle({ ["function"] = "querySelector", key = 1,
        query = "body > li" })
    assert(c == nil, "body > li should not match")
    return true
end

function tests.attribute_value_selector()
    local eng = newDocEngine(SAMPLE)
    local k = eng:handle({ ["function"] = "querySelector", key = 1,
        query = '[data-id="3"]' })
    assert(k, "attr=value selector should match")
    local txt = eng:handle({ ["function"] = "getText", key = k, doc = 1 })
    assert(txt == "Gamma", "text should be Gamma, got " .. tostring(txt))
    return true
end

-- ---------- 属性选择子全集（2026-09-26 真机：豆包漫画搜索/分类"不可用"） ----------
-- 旧实现只认 `[a=v]`：`class*=` 被当成名为 `class*` 的属性 → 恒 nil → 恒不匹配，
-- 而且**不报错**。logcat 里 HTTP 200 / html parse / querySelectorAll 都在，
-- 就是列表空。装机 20 源共 29 处 `*=`/`^=` 受同一影响。

-- 逐节点照抄真机页面（list-area-guonei.html 抓取于 2026-09-26）：
-- li 里 `div.pic > a > div.img-wrapper[data-original]`，标题又在 `div.name > h3 > a`
-- 重复一次，所以一个条目有 2~3 个受同一选择子命中的节点。
local ATTR_SAMPLE = [[
<ul class="row comic-list">
  <li class="col-xs-4 col-md-3 col-lg-2" data-id="7">
    <div class="pic">
      <a href="/detail/ab12.html" title="人间百里锦"><div class="img-wrapper lazy img-wrapper-pic" data-original="https://img.example.com/cover/ab12.webp"></div></a>
    </div>
    <div class="name">
      <h3><a href="/detail/ab12.html" title="人间百里锦">人间百里锦</a></h3>
      <p class="item-status text-overflow">小番外</p>
    </div>
  </li>
  <li class="col-xs-4">
    <div class="pic">
      <a href="/detail/cd34.html" lang="zh-CN"><img data-original="c2.webp"></a>
    </div>
  </li>
  <li class="plain"><span>no link</span></li>
</ul>
]]

local function countAll(eng, q)
    local ks = eng:handle({ ["function"] = "querySelectorAll", key = 1, query = q })
    return type(ks) == "table" and #ks or -1
end

function tests.attribute_operators_substring_prefix_suffix()
    local eng = newDocEngine(ATTR_SAMPLE)
    -- 豆包里那一条原样选择子（值裸写、带连字符）
    assert_eq_count("class*=", 2, countAll(eng, "li[class*=col-]"))
    assert_eq_count("class*= quoted", 2, countAll(eng, 'li[class*="col-"]'))
    assert_eq_count("href^=", 3, countAll(eng, 'a[href^="/detail/"]'))
    assert_eq_count("href$=", 3, countAll(eng, 'a[href$=".html"]'))
    assert_eq_count("presence", 3, countAll(eng, "a[href]"))
    assert_eq_count("no match", 0, countAll(eng, "li[class*=zzz]"))
    return true
end

function tests.attribute_operators_word_and_prefix_dash()
    local eng = newDocEngine(ATTR_SAMPLE)
    -- ~=：按空白分词的整词匹配（`col-xs-4` 不是词 `col`）
    assert_eq_count("class~=col-xs-4", 2, countAll(eng, 'li[class~="col-xs-4"]'))
    assert_eq_count("class~=col", 0, countAll(eng, 'li[class~="col"]'))
    -- |=：整值相等或以「值-」开头
    assert_eq_count("lang|=zh", 1, countAll(eng, 'a[lang|="zh"]'))
    assert_eq_count("lang|=zh-CN", 1, countAll(eng, 'a[lang|="zh-CN"]'))
    assert_eq_count("lang|=en", 0, countAll(eng, 'a[lang|="en"]'))
    return true
end

function tests.attribute_value_may_contain_dot_and_hash()
    -- 复合选择器切分必须整段吃掉 `[...]`：值里的 `.` 曾被当成语义分隔符，
    -- `[href*=".html"]` 被劈成 `[href*="` + `.html` + `"]` → 恒 0 命中
    local eng = newDocEngine(ATTR_SAMPLE)
    assert_eq_count("dot inside value", 3, countAll(eng, "a[href*=\".html\"]"))
    assert_eq_count("tag + bracket + class", 1,
        countAll(eng, "li.col-xs-4[data-id=\"7\"]"))
    return true
end

function tests.child_combinator_applies_to_its_own_part()
    -- `ul > li p`：`>` 只约束 li 必须是 ul 的子元素，p 仍是后代。
    -- 旧扫描把 child 标记错位一格（按 li、p 的顺序变成「p 是 li 的子元素」），
    -- 于是这种写法静默 0 命中。
    local eng = newDocEngine(
        '<ul><li class="a"><div><p>x</p></div></li></ul>')
    assert_eq_count("ul > li p", 1, countAll(eng, "ul > li p"))
    assert_eq_count("ul > li > div > p", 1, countAll(eng, "ul > li > div > p"))
    -- p 是 div 的子元素、不是 li 的 → 这条必须 0 命中（旧写法当成后代，1 命中）
    assert_eq_count("ul li > p", 0, countAll(eng, "ul li > p"))
    return true
end

function tests.doubao_list_page_selectors_match_real_markup()
    -- 豆包漫画 parseListPage/排行的原样选择子（真机 2026-09-26：HTTP 200 之后
    -- querySelectorAll 空命中 → 搜索与分类全是空列表）
    local eng = newDocEngine(ATTR_SAMPLE)
    assert_eq_count("li[class*=col-]", 2, countAll(eng, "li[class*=col-]"))
    assert_eq_count("div.pic a", 2, countAll(eng, "div.pic a"))
    assert_eq_count("a[href*=detail]", 3, countAll(eng, "a[href*=detail]"))
    assert_eq_count("[data-original]", 2, countAll(eng, "[data-original]"))
    -- 命中项的属性确实读得到（源里靠 href 正则取 id）
    local ks = eng:handle({ ["function"] = "querySelectorAll", key = 1,
        query = "a[href*=detail]" })
    local attrs = eng:handle({ ["function"] = "getAttributes", key = ks[1],
        doc = 1 })
    assert(attrs.href == "/detail/ab12.html",
        "first href should be /detail/ab12.html, got " .. tostring(attrs.href))
    return true
end

function tests.groups_and_siblings()
    local eng = newDocEngine(SAMPLE)
    local ks = eng:handle({ ["function"] = "querySelectorAll", key = 1,
        query = ".first, .footer, a" })
    assert(#ks == 3, "group selector should match 3, got " .. tostring(#ks))
    local nxt = eng:handle({ ["function"] = "getNextSibling", key = ks[1],
        doc = 1 })
    local attrs2 = eng:handle({ ["function"] = "getAttributes", key = nxt,
        doc = 1 })
    assert(attrs2["data-id"] == "2",
        "next sibling of .first should be li[data-id=2]")
    return true
end

function tests.entities_and_rawtext()
    local eng = newDocEngine(SAMPLE)
    local k = eng:handle({ ["function"] = "querySelector", key = 1,
        query = "span" })
    local txt = eng:handle({ ["function"] = "getText", key = k, doc = 1 })
    assert(txt == "Text & more", "entity decode failed: " .. tostring(txt))
    local style = eng:handle({ ["function"] = "querySelector", key = 1,
        query = "style" })
    local raw = eng:handle({ ["function"] = "getText", key = style, doc = 1 })
    assert(raw == ".a{color:red}", "rawtext style: " .. tostring(raw))
    return true
end

function tests.nodes_mixed()
    local eng = newDocEngine(SAMPLE)
    local d = eng:handle({ ["function"] = "querySelector", key = 1,
        query = "#main" })
    local ns = eng:handle({ ["function"] = "getNodes", key = d, doc = 1 })
    assert(#ns > 3, "nodes should include text nodes")
    local t1 = eng:handle({ ["function"] = "node_type", key = ns[1], doc = 1 })
    assert(t1 == "text", "first node should be text, got " .. tostring(t1))
    local okel = eng:handle({ ["function"] = "node_toElement", key = ns[2],
        doc = 1 })
    assert(okel, "an element node should convert to element key")
    return true
end

function tests.dispose_clears()
    local eng = newDocEngine(SAMPLE)
    eng:handle({ ["function"] = "dispose", key = 1 })
    local k = eng:handle({ ["function"] = "querySelector", key = 1,
        query = "div" })
    assert(k == nil, "after dispose doc should be empty")
    return true
end

function tests.void_elements_and_selfclose()
    local html = '<div><img src="x.jpg"><br/><p>after</p></div>'
    local eng = newDocEngine(html)
    local ks = eng:handle({ ["function"] = "querySelectorAll", key = 1,
        query = "div > p" })
    assert(#ks == 1, "void elements must not swallow siblings")
    local imgs = eng:handle({ ["function"] = "querySelectorAll", key = 1,
        query = "img" })
    assert(#imgs == 1, "img should exist")
    return true
end

function tests.nested_queries_and_parent()
    local html = '<div class="w"><div class="in"><a href="1">x</a></div></div>'
    local eng = newDocEngine(html)
    local inkey = eng:handle({ ["function"] = "querySelector", key = 1,
        query = ".in" })
    local a = eng:handle({ ["function"] = "dom_querySelector", key = inkey,
        query = "a", doc = 1 })
    assert(a, "dom_querySelector from .in should find a")
    local w = eng:handle({ ["function"] = "getParent", key = a, doc = 1 })
    local cls = eng:handle({ ["function"] = "getClassNames", key = w, doc = 1 })
    assert(cls[1] == "in", "parent of a should be .in")
    return true
end

function tests.get_inner_html()
    local html = '<div class="w"><p>Hello <b>World</b></p></div>'
    local eng = newDocEngine(html)
    local k = eng:handle({ ["function"] = "querySelector", key = 1,
        query = ".w" })
    local ih = eng:handle({ ["function"] = "getInnerHTML", key = k, doc = 1 })    assert(ih == "<p>Hello <b>World</b></p>",
        "innerHTML mismatch: " .. tostring(ih))
    return true
end

-- ---------- 空数组跨桥标记（真机 R5：详情加载失败 "not a function"） ----------
-- 契约锚点（两处都必须成立，缺一即回归）：
--   1) Lua 空表无法表达"数组"：luaJSON 1.3.5 的 IsArray
--      （KOReader 随包 common/json/util.lua:91-100）对无标记空表返回
--      false → 编成 {}；非空连续表 → []。
--   2) init.js 拿到结果立刻按数组消费：querySelectorAll 直接
--      ks.map(...)（vendored/init.js:702）、dom_querySelectorAll:808、
--      getChildren:822、getNodes:836、classNames:871。{} 上没有 map →
--      quickjs "TypeError: not a function" → 源里首次空命中即整页详情失败
--      （baozi.js comic.loadInfo 的 #chapters_other_list 常缺席）。
-- 处置：ARRAY_OPS 的空结果出口统一换成 {__empty_array=true} 标记表，
-- 由 glue __ezv_untag_bytes 还原为 []（wire 形状在 test_jshost_shim 锁）。

local ARRAY_OPS_EMPTY = {
    { fn = "querySelectorAll", docQuery = "li.nope" },
    { fn = "dom_querySelectorAll", via = "span", docQuery = "li.nope" },
    { fn = "getChildren", via = "img" },      -- void 元素：无子节点
    { fn = "getNodes", via = "img" },
    { fn = "getClassNames", via = "span" },   -- span 无 class
}

function tests.empty_array_ops_return_marker()
    local eng = newDocEngine(SAMPLE)
    for _, spec in ipairs(ARRAY_OPS_EMPTY) do
        local msg = { ["function"] = spec.fn, query = spec.docQuery }
        if spec.via then
            msg.key = eng:handle({ ["function"] = "querySelector", key = 1,
                query = spec.via })
            assert(msg.key, "fixture element " .. spec.via .. " must exist")
            msg.doc = 1
        else
            msg.key = 1   -- doc key
        end
        local res = eng:handle(msg)
        assert(type(res) == "table",
            spec.fn .. ": empty result must be a table")
        assert(res.__empty_array == true,
            spec.fn .. ": empty result must be marked {__empty_array=true},"
            .. " got " .. tostring(res.__empty_array))
        assert(#res == 0, spec.fn .. ": marker table must stay empty")
    end
    return true
end

function tests.nonempty_array_ops_stay_plain_arrays()
    local eng = newDocEngine(SAMPLE)
    local ks = eng:handle({ ["function"] = "querySelectorAll", key = 1,
        query = "li.item" })
    assert(#ks == 3, "expected 3 li.item, got " .. tostring(#ks))
    assert(ks.__empty_array == nil,
        "non-empty querySelectorAll must stay a plain array")
    local cls = eng:handle({ ["function"] = "getClassNames", key = ks[1],
        doc = 1 })
    assert(#cls == 2 and cls.__empty_array == nil,
        "non-empty getClassNames must stay a plain array, got "
        .. tostring(#cls))
    local ul = eng:handle({ ["function"] = "querySelector", key = 1,
        query = "ul.list" })
    local kids = eng:handle({ ["function"] = "getChildren", key = ul,
        doc = 1 })
    assert(#kids == 3 and kids.__empty_array == nil,
        "non-empty getChildren must stay a plain array, got " .. tostring(#kids))
    return true
end

function tests.empty_attributes_stay_object()
    -- attributes 是 map（init.js 用 .attributes["src"]），空命中必须编成 {}
    local eng = newDocEngine(SAMPLE)
    local k = eng:handle({ ["function"] = "querySelector", key = 1,
        query = "span" })
    local attrs = eng:handle({ ["function"] = "getAttributes", key = k,
        doc = 1 })
    assert(type(attrs) == "table" and #attrs == 0
        and attrs.__empty_array == nil,
        "empty getAttributes must stay an unmarked object ({}), not []")
    return true
end

function tests.missing_doc_errors_untouched()
    -- 未知 doc → 空数组；未知 op → 错误形状不被数组标记污染
    local eng = HtmlParse.newEngine()
    local res, iserr = eng:handle({ ["function"] = "querySelectorAll",
        key = 99, query = "div" })
    assert(not iserr, "unknown doc is not an engine error")
    assert(res.__empty_array == true,
        "query on unknown doc yields empty array marker, got "
        .. tostring(res.__empty_array))
    local bad = eng:handle({ ["function"] = "noSuchOp", key = 1 })
    assert(bad.__error ~= nil, "unknown op keeps __error shape")
    assert(bad.__empty_array == nil, "error shape must not be array-marked")
    return true
end

return tests
