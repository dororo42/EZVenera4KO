-- M2 T15: htmlparse.lua —— HTML → DOM + CSS 选择器子集
-- 契约（reports/research/01 §2 + vendored init.js L654-995）：
--   每文档 key → 元素句柄表（Dart html 包语义子集）。
--   handler 消息：parse{key,data} / querySelector{key,query} /
--   querySelectorAll / getElementById{id} / dispose{key} /
--   dom_querySelector{key,query} / dom_querySelectorAll{key,query} /
--   getChildren{key} / getNodes{key} / getText / getAttributes /
--   getInnerHTML / getParent / getClassNames / getId / getLocalName /
--   getPreviousSibling / getNextSibling / node_text / node_type /
--   node_toElement（均 {key,doc}）
-- 选择器子集（design §3.4）：tag / #id / .class / [attr] / [attr=v] /
--   后代组合器 / > 子代 / 逗号分组。
-- 解析器：零依赖手写容错解析（void 元素表 + 自闭合 + script/style 原文）。

local HtmlParse = {}
HtmlParse.__index = HtmlParse

local VOID = {
    area=true, base=true, br=true, col=true, embed=true, hr=true,
    img=true, input=true, link=true, meta=true, param=true,
    source=true, track=true, wbr=true,
}
local RAWTEXT = { script=true, style=true, textarea=true, title=true }

local ENT = { amp="&", lt="<", gt=">", quot='"', apos="'", nbsp="\194\160",
              copy="\194\169", mdash="\226\128\148", ndash="\226\128\147",
              hellip="\226\128\166", rsquo="\226\128\153", lsquo="\226\128\152",
              ldquo="\226\128\156", rdquo="\226\128\157", middot="\194\183",
              times="\195\151", laquo="\194\171", raquo="\194\187",
              deg="\194\176", plusmn="\194\177", sect="\194\167",
              para="\194\182", bull="\226\128\162", trade="\226\132\162",
              euro="\226\130\172", pound="\194\163", yen="\194\165",
              cent="\194\162", reg="\194\174", frac12="\194\189",
              sup2="\194\178", eacute="\195\169", egrave="\195\168",
              agrave="\195\160", ccedil="\195\167", uuml="\195\188",
              ouml="\195\182", auml="\195\164", szlig="\195\159" }

local function decodeEntities(s)
    if not s or not s:find("&") then return s or "" end
    return (s:gsub("&(#?%w+);", function(ent)
        if ent:sub(1, 1) == "#" then
            local n
            if ent:sub(2, 2) == "x" or ent:sub(2, 2) == "X" then
                n = tonumber(ent:sub(3), 16)
            else
                n = tonumber(ent:sub(2), 10)
            end
            if n and n < 0x110000 then
                if n < 128 then return string.char(n) end
                if n < 0x800 then
                    return string.char(0xC0 + math.floor(n / 64),
                        0x80 + (n % 64))
                elseif n < 0x10000 then
                    return string.char(0xE0 + math.floor(n / 4096),
                        0x80 + math.floor(n / 64) % 64, 0x80 + (n % 64))
                else
                    return string.char(0xF0 + math.floor(n / 262144),
                        0x80 + math.floor(n / 4096) % 64,
                        0x80 + math.floor(n / 64) % 64, 0x80 + (n % 64))
                end
            end
            return "&" .. ent .. ";"
        end
        return ENT[ent] or ("&" .. ent .. ";")
    end))
end

local function newElem(tag)
    local el = { tag = tag:lower(), attrs = {}, children = {},
                 classes = {}, id = nil, parent = nil }
    return el
end

local function parseAttrs(s)
    local attrs = {}
    local init = 1
    while init <= #s do
        local pos = s:find("[%w_%-:]", init)
        if not pos then break end
        local epos = pos
        while epos <= #s and s:sub(epos, epos):match("[%w_%-:]") do
            epos = epos + 1
        end
        local key = s:sub(pos, epos - 1):lower()
        local val = ""
        if s:sub(epos, epos) == "=" then
            epos = epos + 1
            local q = s:sub(epos, epos)
            if q == '"' or q == "'" then
                local close = s:find(q, epos + 1, true)
                if close then
                    val = s:sub(epos + 1, close - 1)
                    epos = close + 1
                else
                    val = s:sub(epos + 1)
                    epos = #s + 1
                end
            else
                local sp = s:find("[%s]", epos) or (#s + 1)
                val = s:sub(epos, sp - 1)
                epos = sp
            end
        end
        if key ~= "" then attrs[key] = decodeEntities(val) end
        init = epos
    end
    return attrs
end

local function attachClasses(el)
    local cls = el.attrs.class
    if cls and cls ~= "" then
        for w in cls:gmatch("[^%s]+") do el.classes[w] = true end
    end
    if el.attrs.id and el.attrs.id ~= "" then el.id = el.attrs.id end
end

--- 解析 HTML 文本 → doc（{children, nodes, next_key}）
function HtmlParse.parse(html)
    local doc = { children = {}, nodes = {}, next_key = 1 }
    if type(html) ~= "string" or html == "" then return doc end
    local stack = {}
    local root = newElem("#document")
    local top = root
    local i, n = 1, #html

    local function alloc(node)
        local key = doc.next_key
        doc.next_key = key + 1
        doc.nodes[key] = node
        return key
    end
    local function elemKey(el)
        return alloc({ type = "element", el = el })
    end
    local function addText(txt)
        if txt == "" then return end
        local node = { type = "text", text = decodeEntities(txt) }
        alloc(node)
        table.insert(top.children, node)
    end

    while i <= n do
        local lt = html:find("<", i, true)
        if not lt then
            addText(html:sub(i))
            break
        end
        if lt > i then addText(html:sub(i, lt - 1)) end
        local c2 = html:sub(lt + 1, lt + 1)
        if c2 == "!" then
            if html:sub(lt + 2, lt + 3) == "--" then
                local close = html:find("-->", lt + 4, true)
                i = close and (close + 3) or (n + 1)
            else
                local close = html:find(">", lt + 2, true)
                i = close and (close + 1) or (n + 1)
            end
        elseif c2 == "/" then
            local close = html:find(">", lt + 2, true)
            local tag = html:sub(lt + 2, (close or n + 1) - 1):lower()
                :gsub("%s.*$", "")
            if close then i = close + 1 else i = n + 1 end
            for si = #stack, 1, -1 do
                if stack[si].tag == tag then
                    for _ = #stack, si, -1 do table.remove(stack) end
                    break
                end
            end
            top = stack[#stack] or root
        else
            local close = html:find(">", lt + 1, true)
            if not close then break end
            local inner = html:sub(lt + 1, close - 1)
            local selfclose = inner:sub(-1) == "/"
            if selfclose then inner = inner:sub(1, -2) end
            local tag = inner:match("^%s*([%w%-_:]+)")
            if not tag then
                i = close + 1
            else
                local el = newElem(tag)
                el.attrs = parseAttrs(inner:sub(#tag + 1))
                attachClasses(el)
                el.parent = (top ~= root) and top or nil
                alloc({ type = "element", el = el })
                table.insert(top.children, el)
                if not selfclose and not VOID[el.tag] then
                    if RAWTEXT[el.tag] then
                        local rawclose = html:find("</" .. el.tag, close, true)
                        if rawclose then
                            local raw = html:sub(close + 1, rawclose - 1)
                            if raw ~= "" then
                                local node = { type = "text", text = raw }
                                alloc(node)
                                table.insert(el.children, node)
                            end
                            local gt = html:find(">", rawclose, true)
                            i = gt and (gt + 1) or (n + 1)
                        else
                            i = n + 1
                        end
                    else
                        table.insert(stack, el)
                        top = el
                        i = close + 1
                    end
                else
                    i = close + 1
                end
            end
        end
        top = stack[#stack] or root
    end
    -- doc.children 与 #document 根 children 同表（查询根入口）
    doc.children = root.children
    return doc
end

-- ---------- 选择器 ----------

local function splitTop(s, sep)
    local out, cur, instr = {}, {}, false
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch == "[" then instr = true end
        if ch == "]" then instr = false end
        if not instr and ch == sep then
            table.insert(out, table.concat(cur))
            cur = {}
        else
            table.insert(cur, ch)
        end
    end
    table.insert(out, table.concat(cur))
    return out
end

local function matchesCompound(el, compound)
    if not el or not compound or compound == "" then return false end
    for tok in compound:gmatch("[#%.%[]?[^#%.%[]+") do
        if tok and tok ~= "" then
            local c1 = tok:sub(1, 1)
            if c1 == "#" then
                if el.id ~= tok:sub(2) then return false end
            elseif c1 == "." then
                if not el.classes[tok:sub(2)] then return false end
            elseif c1 == "[" then
                local attr, val = tok:match("^%[([^=%]]+)=([^%]]*)%]$")
                if attr then
                    local av = el.attrs[attr:lower()]
                    if av == nil then return false end
                    val = val:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
                    if av ~= val then return false end
                else
                    local a2 = tok:match("^%[([^%]]+)%]$")
                    if a2 and el.attrs[a2:lower()] == nil then return false end
                end
            else
                if tok ~= "*" and el.tag ~= tok:lower() then return false end
            end
        end
    end
    return true
end

local function collectDesc(el, out)
    for _, ch in ipairs(el.children) do
        if ch.tag then
            table.insert(out, ch)
            collectDesc(ch, out)
        end
    end
end

local function matchFrom(el, parts, idx)
    if not el then return false end
    local p = parts[idx]
    if not matchesCompound(el, p.comb) then return false end
    if idx == 1 then return true end
    if p.child then
        return matchFrom(el.parent, parts, idx - 1)
    end
    local anc = el.parent
    while anc do
        if matchFrom(anc, parts, idx - 1) then return true end
        anc = anc.parent
    end
    return false
end

local function queryImpl(roots, selector)
    local out, seen = {}, {}
    for _, group in ipairs(splitTop(selector or "", ",")) do
        group = (group:gsub("^%s+", "")):gsub("%s+$", "")
        if group ~= "" then
            local parts, cur = {}, {}
            local childNext = false
            for i = 1, #group do
                local ch = group:sub(i, i)
                if ch == ">" then
                    if #cur > 0 then
                        table.insert(parts, { comb = table.concat(cur), child = false })
                        cur = {}
                    end
                    childNext = true
                elseif ch == " " then
                    if #cur > 0 then
                        table.insert(parts, { comb = table.concat(cur), child = false })
                        cur = {}
                    end
                else
                    table.insert(cur, ch)
                end
            end
            if #cur > 0 then
                table.insert(parts, { comb = table.concat(cur), child = childNext })
            end
            local cands = {}
            for _, r in ipairs(roots) do
                if r.tag then
                    table.insert(cands, r)
                    collectDesc(r, cands)
                end
            end
            for _, el in ipairs(cands) do
                if not seen[el] and matchFrom(el, parts, #parts) then
                    seen[el] = true
                    table.insert(out, el)
                end
            end
        end
    end
    return out
end

-- ---------- 引擎：每 doc 一个解析缓存 ----------

--- 数组形状的 op（结果直接给 JS 当数组用）。
--- 真机 R5（"详情加载失败：not a function"）根因：Lua 空表没有长度信息，
--- JSON 编码出去必然是 {}，而 init.js 拿到结果立刻 .map：
---   querySelectorAll → vendored/init.js:702、dom_querySelectorAll:808、
---   getChildren:822、getNodes:836，classNames:871 亦按 string[] 消费。
--- {} 上不存在 map → quickjs TypeError "not a function"（源里首次
--- querySelectorAll 空命中即整页详情加载失败）。luaJSON 1.3.5 的数组判定
--- （随包 common/json/util.lua:91-100 IsArray）对无标记空表返回 false，
--- 故不能靠"猜长度"；统一在出口打显式空数组标记 {__empty_array=true}，
--- 由 glue 的 __ezv_untag_bytes 还原为 []（与 __bytes_b64 同一约定，
--- 见 runtime/jshost.lua 注释）。非空结果本身就是 JSON 数组，无需标记。
local ARRAY_OPS = {
    querySelectorAll = true, dom_querySelectorAll = true,
    getChildren = true, getNodes = true, getClassNames = true,
}

function HtmlParse.newEngine()
    local engine = { docs = {} }
    local function docFor(key) return engine.docs[key] end

    local handlers = {}
    handlers["parse"] = function(msg)
        engine.docs[msg.key] = HtmlParse.parse(msg.data)
        return true
    end
    handlers["dispose"] = function(msg)
        engine.docs[msg.key] = nil
        return true
    end
    local function elemByKey(msg)
        local doc = docFor(msg.doc)
        if not doc then return nil end
        local node = doc.nodes[msg.key]
        if node and node.type == "element" then return node.el end
        return nil
    end
    local function docRoots(msg)
        local doc = docFor(msg.key)
        return doc and doc.children or {}
    end
    handlers["querySelector"] = function(msg)
        local doc = docFor(msg.key)
        local m = queryImpl(doc and doc.children or {}, msg.query)[1]
        if not m or not doc then return nil end
        local key = doc.next_key; doc.next_key = key + 1
        doc.nodes[key] = { type = "element", el = m }
        return key
    end
    handlers["querySelectorAll"] = function(msg)
        local doc = docFor(msg.key)
        local out = {}
        for _, el in ipairs(queryImpl(docRoots(msg), msg.query)) do
            local key = doc.next_key; doc.next_key = key + 1
            doc.nodes[key] = { type = "element", el = el }
            table.insert(out, key)
        end
        return out
    end
    handlers["dom_querySelector"] = function(msg)
        local el = elemByKey(msg)
        if not el then return nil end
        local m = queryImpl({ el }, msg.query)[1]
        if not m then return nil end
        local doc = docFor(msg.doc)
        local key = doc.next_key; doc.next_key = key + 1
        doc.nodes[key] = { type = "element", el = m }
        return key
    end
    handlers["dom_querySelectorAll"] = function(msg)
        local el = elemByKey(msg)
        if not el then return {} end
        local doc = docFor(msg.doc)
        local out = {}
        for _, m in ipairs(queryImpl({ el }, msg.query)) do
            local key = doc.next_key; doc.next_key = key + 1
            doc.nodes[key] = { type = "element", el = m }
            table.insert(out, key)
        end
        return out
    end
    handlers["getElementById"] = function(msg)
        local doc = docFor(msg.key)
        local m = queryImpl(doc and doc.children or {},
            "#" .. tostring(msg.id))[1]
        if not m or not doc then return nil end
        local key = doc.next_key; doc.next_key = key + 1
        doc.nodes[key] = { type = "element", el = m }
        return key
    end
    handlers["getChildren"] = function(msg)
        local el = elemByKey(msg)
        if not el then return {} end
        local doc = docFor(msg.doc)
        local out = {}
        for _, ch in ipairs(el.children) do
            if ch.tag then
                local key = doc.next_key; doc.next_key = key + 1
                doc.nodes[key] = { type = "element", el = ch }
                table.insert(out, key)
            end
        end
        return out
    end
    handlers["getNodes"] = function(msg)
        local el = elemByKey(msg)
        if not el then return {} end
        local doc = docFor(msg.doc)
        local out = {}
        for _, ch in ipairs(el.children) do
            local node = ch.tag and { type = "element", el = ch } or ch
            local key = doc.next_key; doc.next_key = key + 1
            doc.nodes[key] = node
            table.insert(out, key)
        end
        return out
    end
    handlers["getText"] = function(msg)
        local el = elemByKey(msg)
        if not el then return "" end
        local out = {}
        local function walk(e)
            for _, ch in ipairs(e.children) do
                if ch.tag then walk(ch)
                elseif ch.type == "text" then table.insert(out, ch.text) end
            end
        end
        walk(el)
        return table.concat(out)
    end
    handlers["getInnerHTML"] = function(msg)
        local el = elemByKey(msg)
        if not el then return "" end
        local out = {}
        local function ser(e)
            table.insert(out, "<" .. e.tag)
            for k, v in pairs(e.attrs) do
                table.insert(out, (' %s="%s"'):format(k, (v:gsub('"', "&quot;"))))
            end
            table.insert(out, ">")
            for _, ch in ipairs(e.children) do
                if ch.tag then ser(ch)
                elseif ch.type == "text" then
                    table.insert(out, (ch.text:gsub("<", "&lt;")))
                end
            end
            table.insert(out, "</" .. e.tag .. ">")
        end
        for _, ch in ipairs(el.children) do
            if ch.tag then ser(ch)
            elseif ch.type == "text" then
                table.insert(out, (ch.text:gsub("<", "&lt;")))
            end
        end
        return table.concat(out)
    end
    handlers["getAttributes"] = function(msg)
        local el = elemByKey(msg)
        return el and el.attrs or {}
    end
    handlers["getParent"] = function(msg)
        local el = elemByKey(msg)
        if not el or not el.parent then return nil end
        -- #document 根不算元素父（返回 nil 与 Dart 一致）
        if el.parent.tag == "#document" then return nil end
        local doc = docFor(msg.doc)
        local key = doc.next_key; doc.next_key = key + 1
        doc.nodes[key] = { type = "element", el = el.parent }
        return key
    end
    handlers["getClassNames"] = function(msg)
        local el = elemByKey(msg)
        if not el then return {} end
        local out = {}
        for k in pairs(el.classes) do table.insert(out, k) end
        table.sort(out)
        return out
    end
    handlers["getId"] = function(msg)
        local el = elemByKey(msg)
        return el and el.id or nil
    end
    handlers["getLocalName"] = function(msg)
        local el = elemByKey(msg)
        return el and el.tag or ""
    end
    handlers["getPreviousSibling"] = function(msg)
        local el = elemByKey(msg)
        if not el or not el.parent then return nil end
        local prev
        for _, ch in ipairs(el.parent.children) do
            if ch == el then break end
            if ch.tag then prev = ch end
        end
        if not prev then return nil end
        local doc = docFor(msg.doc)
        local key = doc.next_key; doc.next_key = key + 1
        doc.nodes[key] = { type = "element", el = prev }
        return key
    end
    handlers["getNextSibling"] = function(msg)
        local el = elemByKey(msg)
        if not el or not el.parent then return nil end
        local found
        for _, ch in ipairs(el.parent.children) do
            if found and ch.tag then
                local doc = docFor(msg.doc)
                local key = doc.next_key; doc.next_key = key + 1
                doc.nodes[key] = { type = "element", el = ch }
                return key
            end
            if ch == el then found = true end
        end
        return nil
    end
    handlers["node_text"] = function(msg)
        local doc = docFor(msg.doc)
        local node = doc and doc.nodes[msg.key]
        return (node and node.type == "text") and node.text or ""
    end
    handlers["node_type"] = function(msg)
        local doc = docFor(msg.doc)
        local node = doc and doc.nodes[msg.key]
        return node and node.type or "unknown"
    end
    handlers["node_toElement"] = function(msg)
        local doc = docFor(msg.doc)
        local node = doc and doc.nodes[msg.key]
        if node and node.type == "element" then
            local key = doc.next_key; doc.next_key = key + 1
            doc.nodes[key] = { type = "element", el = node.el }
            return key
        end
        return nil
    end

    function engine:handle(msg)
        local h = handlers[msg["function"]]
        if not h then
            return { __error = "html: unknown function "
                .. tostring(msg["function"]) }, true
        end
        local ok, res = pcall(h, msg)
        if not ok then
            return { __error = "html: " .. tostring(res) }, true
        end
        if ARRAY_OPS[msg["function"]] and type(res) == "table" and #res == 0 then
            res = { __empty_array = true }
        end
        return res, false
    end
    return engine
end

return HtmlParse
