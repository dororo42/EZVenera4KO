-- unit test: runtime/sources.lua — 源仓库（R3.4 / M2 T16）
-- 桩注入：netclient（固定响应）/ convert（确定性 sha）/ json（dkjson 式纯 Lua
-- 解析桩覆盖测试 fixture 子集）/ datadir（Windows 兼容临时目录）
local Sources = require("runtime.sources")

local tests = {}

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
end

-- ---------- 纯 Lua JSON 桩（覆盖 fixture 子集：数组/对象/字符串/数字） ----------
local J
do
    local function skipws(s, i)
        while i <= #s and s:sub(i, i):match("%s") do i = i + 1 end
        return i
    end
    local function parseVal(s, i)
        i = skipws(s, i)
        local c = s:sub(i, i)
        if c == "[" then
            local arr = {}
            i = skipws(s, i + 1)
            if s:sub(i, i) == "]" then return arr, i + 1 end
            while true do
                local v; v, i = parseVal(s, i)
                table.insert(arr, v)
                i = skipws(s, i)
                if s:sub(i, i) == "," then i = i + 1
                elseif s:sub(i, i) == "]" then return arr, i + 1
                else error("bad arr at " .. i) end
            end
        elseif c == "{" then
            local obj = {}
            i = skipws(s, i + 1)
            if s:sub(i, i) == "}" then return obj, i + 1 end
            while true do
                i = skipws(s, i)
                local k
                local k0, k1 = s:find('"([^"]+)"', i)
                k = s:sub(k0 + 1, k1 - 1)
                i = skipws(s, k1 + 1)
                assert(s:sub(i, i) == ":", "bad obj at " .. i)
                local v; v, i = parseVal(s, i + 1)
                obj[k] = v
                i = skipws(s, i)
                if s:sub(i, i) == "," then i = i + 1
                elseif s:sub(i, i) == "}" then return obj, i + 1
                else error("bad obj at " .. i) end
            end
        elseif c == '"' then
            local a, b = s:find('"([^"]*)"', i)
            return s:sub(a + 1, b - 1), b + 1
        else
            local num = s:match("^%-?[%d%.]+", i)
            return tonumber(num), i + #num
        end
    end
    J = {
        decode = function(s) return parseVal(s, 1) end,
        encode = function(v) return "stub-encoded" end,
    }
end

local INDEX_BODY = [[
[
 {"name":"JM","fileName":"jm.js","key":"jm","version":"1.0.0"},
 {"name":"CopyManga","fileName":"copy_manga.js","key":"copy","version":"2.1.0","description":"copymanga"},
 {"name":"LocalOnly","fileName":"local.js","key":"conflict","version":"9.9"}
]
]]

local JM_JS = "-- jm source\nfunction onLoad() end\n"

local function fakeNet(responses)
    return {
        request = function(_, opts)
            local url = opts.url or ""
            for pat, r in pairs(responses) do
                if url:find(pat) then
                    return { status = r[1], body = r[2] }
                end
            end
            return { status = 404, body = "" }
        end,
    }
end

local fakeConvert = {
    sha256hex = function(s)
        local h = 0
        for i = 1, #s do h = (h * 31 + s:byte(i)) % 0xFFFFFFFF end
        return ("%08x%08x%08x%08x"):format(h, #s, 0xdead, 0xbeef)
    end,
}

-- Windows 兼容临时目录（%TEMP%）
local TMP = os.getenv("TEMP") or "/tmp"
local seq = 0
local function makeSrc(net)
    seq = seq + 1
    local datadir = TMP .. "/ezv_test_" .. tostring(seq) .. "_" ..
        tostring(os.time() % 100000)
    os.execute('mkdir "' .. datadir .. '" 2>nul')
    os.execute('mkdir -p "' .. datadir .. '" 2>/dev/null')
    return Sources.new{
        netclient = net,
        convert = fakeConvert,
        datadir = datadir,
        json = J,
    }
end

function tests.fetch_index_default_and_fallback()
    local net = fakeNet{
        ["raw%.githubusercontent%.com"] = {200, INDEX_BODY},
    }
    local s = makeSrc(net)
    local list, err = s:fetchIndex()
    assert(list, "index should fetch: " .. tostring(err))
    assert(#list == 3, "3 entries, got " .. tostring(#list))
    return true
end

function tests.fetch_index_cdn_fallback()
    local net = fakeNet{
        ["raw%.githubusercontent%.com"] = {404, ""},
        ["cdn%.jsdelivr%.net"] = {200, INDEX_BODY},
    }
    local s = makeSrc(net)
    local list, err = s:fetchIndex()
    assert(list, "CDN fallback should work: " .. tostring(err))
    assert(#list == 3, "CDN entries 3")
    return true
end

function tests.install_writes_file_and_manifest()
    local net = fakeNet{
        ["jm%.js"] = {200, JM_JS},
    }
    local s = makeSrc(net)
    local ok, entry = s:install(
        {key="jm", fileName="jm.js", name="JM", version="1.0.0"})
    assert(ok, "install should succeed: " .. tostring(entry))
    assert(type(entry.sha256) == "string" and entry.sha256 ~= "", "sha recorded")
    local body = s:readSource("jm")
    assert(body == JM_JS, "source file roundtrip")
    local inst = s:listInstalled()
    assert(#inst == 1 and inst[1].key == "jm", "manifest has jm")
    return true
end

function tests.remove_deletes()
    local net = fakeNet{
        ["jm%.js"] = {200, JM_JS},
    }
    local s = makeSrc(net)
    s:install({key="jm", fileName="jm.js", name="JM"})
    local ok = s:remove("jm")
    assert(ok, "remove ok")
    assert(s:readSource("jm") == nil, "source file deleted")
    assert(#s:listInstalled() == 0, "manifest empty")
    return true
end

function tests.install_local_file()
    local s = makeSrc(fakeNet{})
    local path = s.datadir .. "/mysource.js"
    local f = io.open(path, "w")
    assert(f, "tmp dir writable: " .. path)
    f:write("local x = 1")
    f:close()
    local ok, entry = s:installLocalFile(path)
    assert(ok, "local install: " .. tostring(entry))
    assert(s:readSource("mysource") ~= nil, "file installed")
    return true
end

function tests.install_requires_key_and_filename()
    local s = makeSrc(fakeNet{})
    local ok, err = s:install({name="bad"})
    assert(not ok, "install without key/fileName must fail")
    return true
end

-- ---------- 添加自定义漫画源（任意 URL / 自定义索引 / 边车基址） ----------

local MY_JS = "-- my custom source\nfunction onLoad() end\n"

-- 记录请求地址的 net（断言"到底去哪个 URL 取的文件"）
local function recNet(responses, log)
    return {
        request = function(_, opts)
            table.insert(log, tostring(opts.url))
            for pat, r in pairs(responses or {}) do
                if (opts.url or ""):find(pat) then
                    return { status = r[1], body = r[2] }
                end
            end
            return { status = 404, body = "" }
        end,
    }
end

-- 测试进程里没有 lfs（KOReader 里叫 libs/libkoreader-lfs），要测列目录的逻辑
-- 只能自己塞一个：dir 回放测试登记的名单，mkdir 走真命令（保证文件真写得下去）。
local function withFakeLfs(list)
    package.loaded["lfs"] = {
        mkdir = function(d)
            os.execute('mkdir "' .. d .. '" 2>nul')
            os.execute('mkdir -p "' .. d .. '" 2>/dev/null')
        end,
        dir = function()
            local i = 0
            return function()
                i = i + 1
                return list[i]      -- 真 lfs.dir 只产出名字，不带索引
            end
        end,
    }
    return function() package.loaded["lfs"] = nil end
end

function tests.install_from_url_derives_key_and_base()
    local log = {}
    local s = makeSrc(recNet({ ["my_src%.js"] = {200, MY_JS} }, log))
    local ok, entry = s:installFromURL("https://例.网/manga/my_src.js")
    assert(ok, "installFromURL should succeed: " .. tostring(entry))
    assert_eq("key 取自文件名", "my_src", entry.key)
    assert_eq("name 缺省等于 key", "my_src", entry.name)
    assert_eq("只请求自定义地址一次", 1, #log)
    assert_eq("请求地址", "https://例.网/manga/my_src.js", log[1])
    assert_eq("清单记基址", "https://例.网/manga/", entry.source)
    assert(s:readSource("my_src") == MY_JS, "源文件落盘可回读")
    return true
end

function tests.install_from_url_strips_query_and_takes_name()
    local s = makeSrc(fakeNet{ ["bad%.js"] = {200, MY_JS} })
    local ok, entry = s:installFromURL(
        "https://host/dir/bad.js?token=abc#frag", "我的坏源")
    assert(ok, "带查询串的 URL 也应能装: " .. tostring(entry))
    assert_eq("name 用传入的", "我的坏源", entry.name)
    return true
end

function tests.install_from_url_rejects_bad_urls()
    local s = makeSrc(fakeNet{})
    for _, bad in ipairs({ nil, "", "ftp://h/x.js", "not a url" }) do
        local ok, err = s:installFromURL(bad)
        assert(not ok, "应拒绝: " .. tostring(bad))
        assert(type(err) == "string" and err ~= "", "拒绝要给原因")
    end
    return true
end

-- 自定义索引里的源不在官方基址下：entry._base 必须优先，否则永远 404。
function tests.install_prefers_entry_base()
    local log = {}
    local s = makeSrc(recNet({ ["mine%.example"] = {200, MY_JS} }, log))
    local ok, entry = s:install({
        key = "mine", fileName = "mine.js", name = "Mine",
        _base = "https://mine.example/src/",
    })
    assert(ok, "install with _base: " .. tostring(entry))
    assert_eq("只打一次（不回落官方基址）", 1, #log)
    assert_eq("URL", "https://mine.example/src/mine.js", log[1])
    return true
end

function tests.add_custom_index_writes_body_and_sidecar()
    local s = makeSrc(fakeNet{ ["index%.json"] = {200, INDEX_BODY} })
    local ok, res = s:addCustomIndex("https://mine.example/dir/index.json")
    assert(ok, "addCustomIndex should succeed: " .. tostring(res))
    assert_eq("条目数", 3, res.count)
    assert_eq("基址", "https://mine.example/dir/", res.base)
    local pdir = s:localIndexDir()
    local f = io.open(pdir .. "/" .. res.file .. ".json", "r")
    assert(f, "索引原文应落盘")
    local body = f:read("*a"); f:close()
    assert_eq("原文无损（不重新编码）", INDEX_BODY, body)
    local bf = io.open(pdir .. "/" .. res.file .. ".base", "r")
    assert(bf, "基址边车文件应存在")
    local b = bf:read("*a"); bf:close()
    assert_eq("边车基址", "https://mine.example/dir/", b)
    return true
end

function tests.add_custom_index_rejects_bad_payloads()
    local s1 = makeSrc(fakeNet{ ["a%.com"] = {404, ""} })
    local ok, err = s1:addCustomIndex("https://a.com/index.json")
    assert(not ok, "非 200 要失败")
    local s2 = makeSrc(fakeNet{ ["b%.com"] = {200, "not json at all"} })
    assert(not s2:addCustomIndex("https://b.com/index.json"), "非法 JSON 要失败")
    local s3 = makeSrc(fakeNet{
        ["c%.com"] = {200, '[{"name":"no fileName","key":"k"}]'} })
    assert(not s3:addCustomIndex("https://c.com/index.json"),
        "条目缺 fileName 要失败")
    assert(not s3:addCustomIndex("mailto:nobody@x"), "非 http 地址要失败")
    return true
end

function tests.merge_local_attaches_sidecar_base()
    local s = makeSrc(fakeNet{})
    local pdir = s:localIndexDir()
    local f = io.open(pdir .. "/custom_mine.json", "w")
    f:write(INDEX_BODY); f:close()
    local bf = io.open(pdir .. "/custom_mine.base", "w")
    bf:write("https://mine.example/dir/\n"); bf:close()
    local undo = withFakeLfs({ "custom_mine.json", "custom_mine.base" })
    local merged = s:mergeLocal{
        { key = "outsider", fileName = "out.js", name = "RemoteOnly" },
        { key = "conflict", fileName = "local.js", name = "RemoteDup" },
    }
    undo()
    local byKey = {}
    for _, e in ipairs(merged) do byKey[e.key] = e end
    assert_eq("本地 3 条 + 远端独有 1 条", 4, #merged)
    -- INDEX_BODY 里那条的 key 是 conflict、name 是 LocalOnly
    assert_eq("边车基址挂上条目", "https://mine.example/dir/",
        byKey.conflict and byKey.conflict._base)
    assert_eq("同 key 本地优先", "LocalOnly",
        byKey.conflict and byKey.conflict.name)
    assert_eq("远端条目不带 _base", nil, byKey.outsider and byKey.outsider._base)
    return true
end

function tests.list_and_remove_custom_index()
    local s = makeSrc(fakeNet{ ["index%.json"] = {200, INDEX_BODY} })
    local ok, res = s:addCustomIndex("https://mine.example/dir/index.json")
    assert(ok, "先加一份: " .. tostring(res))
    local undo = withFakeLfs({ res.file .. ".json", res.file .. ".base",
        "installed.json" })
    local list = s:listCustomIndexes()
    undo()
    assert_eq("只认 custom_ 前缀", 1, #list)
    assert_eq("条数", 3, list[1].count)
    assert_eq("基址", "https://mine.example/dir/", list[1].base)
    assert_eq("标识", res.file, list[1].file)

    local rok, rerr = s:removeCustomIndex("../installed")
    assert(not rok, "路径穿越要拒绝: " .. tostring(rerr))
    assert(not s:removeCustomIndex("random"), "非 custom_ 前缀要拒绝")
    local dok, derr = s:removeCustomIndex(res.file)
    assert(dok, "删除应成功: " .. tostring(derr))
    local pdir = s:localIndexDir()
    assert(not io.open(pdir .. "/" .. res.file .. ".json", "r"), "json 已删")
    assert(not io.open(pdir .. "/" .. res.file .. ".base", "r"), "base 已删")
    assert(not s:removeCustomIndex(res.file), "再删应报找不到")
    return true
end

return tests
