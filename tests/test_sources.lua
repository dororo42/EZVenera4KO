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


-- ---------- 本地整包导入（移植流水线产物：manifest.json + 同目录 .js） ----------

local BUNDLE_MAN = [[
[
 {"name":"Alpha","fileName":"a.js","key":"alpha","version":"1.0.0"},
 {"name":"Beta","fileName":"b.js","key":"beta","version":"1.0.0","description":"移植"}
]
]]
local ALPHA_JS = "class AlphaSource extends ComicSource { key = \"alpha\"; }\nexport default AlphaSource;\n"
local BETA_JS = "export default class BetaSource extends ComicSource { key = \"beta\"; }\n"

-- 往目录里写文件（离线包只涉及本地 IO，不用 net 桩）
local function writeFile(path, body)
    local f = io.open(path, "w")
    assert(f, "cannot write " .. path)
    f:write(body)
    f:close()
end

function tests.install_local_bundle_uses_manifest_name_and_version()
    local s = makeSrc(fakeNet{})
    writeFile(s.datadir .. "/manifest.json", BUNDLE_MAN)
    writeFile(s.datadir .. "/a.js", ALPHA_JS)
    writeFile(s.datadir .. "/b.js", BETA_JS)
    -- 故意带尾斜杠：路径拼接不能因此多出 //
    local res, err = s:installLocalBundle(s.datadir .. "/")
    assert(res, "bundle import should succeed: " .. tostring(err))
    assert_eq("n_ok", 2, res.n_ok)
    assert_eq("n_fail", 0, res.n_fail)
    assert_eq("条目数", 2, #res.list)
    local inst = s:listInstalled()
    local byk = {}
    for _, e in ipairs(inst) do byk[e.key] = e end
    assert_eq("alpha 显示名取自索引", "Alpha", byk.alpha.name)
    assert_eq("alpha 版本取自索引", "1.0.0", byk.alpha.version)
    assert_eq("beta 显示名", "Beta", byk.beta.name)
    -- listInstalled() 只投影 key/name/version，source 字段要看原始清单
    local raw = s:installed()
    assert(raw.alpha.source:find("^local:") ~= nil, "source 标记为 local:")
    assert_eq("js 内容原样落盘", ALPHA_JS, s:readSource("alpha"))
    return true
end

function tests.install_local_bundle_accepts_index_json_name()
    local s = makeSrc(fakeNet{})
    writeFile(s.datadir .. "/index.json", BUNDLE_MAN)
    writeFile(s.datadir .. "/a.js", ALPHA_JS)
    writeFile(s.datadir .. "/b.js", BETA_JS)
    local res, err = s:installLocalBundle(s.datadir)
    assert(res, "index.json 也该认: " .. tostring(err))
    assert_eq("n_ok", 2, res.n_ok)
    return true
end

function tests.install_local_bundle_missing_manifest_errors()
    local s = makeSrc(fakeNet{})
    local res, err = s:installLocalBundle(s.datadir)
    assert(res == nil, "缺索引必须报错")
    assert(tostring(err):find("manifest") ~= nil, "报错要提到 manifest: " .. tostring(err))
    local bad = s:installLocalBundle("")
    assert(bad == nil, "空路径报错")
    return true
end

function tests.install_local_bundle_counts_per_entry_failures()
    local s = makeSrc(fakeNet{})
    writeFile(s.datadir .. "/manifest.json", BUNDLE_MAN)
    writeFile(s.datadir .. "/a.js", ALPHA_JS)   -- b.js 故意不写
    local res, err = s:installLocalBundle(s.datadir)
    assert(res, "整包不该整体失败: " .. tostring(err))
    assert_eq("成功 1", 1, res.n_ok)
    assert_eq("失败 1", 1, res.n_fail)
    assert_eq("第一个条目 ok", true, res.list[1].ok)
    assert_eq("第二个条目 fail", false, res.list[2].ok)
    assert(res.list[2].err ~= nil and res.list[2].err ~= "", "失败要带原因")
    assert(s:readSource("alpha") ~= nil, "good 条目仍然装上")
    assert(s:readSource("beta") == nil, "缺失文件不该留下空条目")
    return true
end

function tests.install_local_file_keeps_meta()
    local s = makeSrc(fakeNet{})
    writeFile(s.datadir .. "/x.js", "class X extends ComicSource {}")
    local ok, e = s:installLocalFile(s.datadir .. "/x.js", "x",
        { name = "X 番工坊", version = "2.3.4" })
    assert(ok, "local install: " .. tostring(e))
    assert_eq("meta.name", "X 番工坊", e.name)
    assert_eq("meta.version", "2.3.4", e.version)
    local ok2, e2 = s:installLocalFile(s.datadir .. "/x.js", "y")
    assert(ok2, "无 meta 仍可用: " .. tostring(e2))
    assert_eq("缺省 name = key", "y", e2.name)
    assert_eq("缺省 version = local", "local", e2.version)
    return true
end

function tests.remove_unknown_key_errors()
    local s = makeSrc(fakeNet{})
    local ok, err = s:remove("never_installed")
    assert_eq("不存在的 key 删不掉", false, ok)
    assert(tostring(err):find("not installed") ~= nil,
        "报错要说清原因: " .. tostring(err))
    return true
end

-- 真机教训：整包导入带了个和已装源同名的 zaimanhua，把用户自己装的
-- v1.0.2 静默换成 v1.0.0。覆盖可以是想要的，但必须在导入结果里看得见。
function tests.install_local_bundle_counts_overwrites()
    local s = makeSrc(fakeNet{})
    writeFile(s.datadir .. "/manifest.json", BUNDLE_MAN)
    writeFile(s.datadir .. "/a.js", ALPHA_JS)
    writeFile(s.datadir .. "/b.js", BETA_JS)
    -- 先单装一个 alpha（模拟用户自己装过）
    local ok0 = s:installLocalFile(s.datadir .. "/a.js", "alpha",
        { name = "Alpha 旧版", version = "9.9.9" })
    assert(ok0, "预装 alpha")
    local res, err = s:installLocalBundle(s.datadir)
    assert(res, "整包导入应成功: " .. tostring(err))
    assert_eq("n_ok", 2, res.n_ok)
    assert_eq("n_over", 1, res.n_over)
    assert_eq("条目 1 标记覆盖", true, res.list[1].overwrite)
    assert_eq("记下被覆盖的旧版本", "9.9.9", res.list[1].prev_version)
    assert_eq("条目 2 未覆盖", nil, res.list[2].overwrite)
    return true
end

return tests
