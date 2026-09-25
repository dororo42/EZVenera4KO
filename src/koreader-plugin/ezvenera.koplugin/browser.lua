-- M2 T17: browser.lua —— 浏览 UI（R3.5）
-- 流程：源列表 → 分类/搜索 → 结果列表 → 详情 → 章节 → T18 阅读器
-- 组件范式：opds.koplugin（Menu:new + onMenuSelect + UIManager:show/close）
-- 异步：源方法多为 async（返回 promise）——eval 内置同步泵排空微任务，
-- 结果经 __ezv_ret 槽位取回（见 _awaitSource）。长请求经 netclient 短超时。

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("gettext")

local Browser = {}
Browser.__index = Browser

local SourceData = require("runtime/sourcedata")
local Downloader = require("runtime/downloader")
-- 只借它的 JSON null 哨兵剥离（见 jshost.isNullSentinel）：源数据里
-- `"author": null` 解出来是 truthy 的 function/lightuserdata，界面任何一次
-- `if x.author then` 都会被它骗过（真机源菜单崩在 acc.login 上同一根因）。
local JsHost = require("runtime/jshost")
--- deps: engine(JsHost), sources(Sources), infoMessage(fn), closeMenu(fn)
function Browser.new(deps)
    local o = setmetatable({}, Browser)
    o.engine = deps.engine
    o.sources = deps.sources
    o.infoMessage = deps.infoMessage or function(text)
        UIManager:show(InfoMessage:new{ text = text })
    end
    o.netclient = deps.netclient
    o.convert = deps.convert
    o.cookies = deps.cookies
    o.settings = deps.settings
    -- 收藏夹 + 阅读历史（library.lua）；缺省不影响其余流程
    o.library = deps.library
    -- 源参数/登录态存储（runtime/sourcedata.lua）；单测注入内存后端
    o.sourcedata = deps.sourcedata
    -- 阅读页字节缓存预算（可调，默认见 showReader）
    o.page_cache_bytes = deps.page_cache_bytes
    -- 解码后 BlitBuffer 的内存预算（一页 ≈ 宽×高×通道，Android 内存紧张）
    o.page_bb_bytes = deps.page_bb_bytes
    -- 离线下载根目录（单测注入临时目录；真机走 DataStorage）
    o.downloads_dir = deps.downloads_dir
    -- 直接注入下载器（单测给内存 fs；真机不传，见 getDownloader）
    o.downloader = deps.downloader
    return o
end

--- 源里 "Not logged in" 这类抛出文案对用户毫无指导性（真机反馈：装了 picacg
--- 只看得到报错，不知道该去哪登录）。识别出来就补一句入口指引。
--- 【2026-09-24 上移】发现(explore)分支也要用，而它位于本文件更靠前处
--- ——local function 只对**之后**编译到的代码可见，放下面会取到 nil。
local function loginHint(err)
    local s = tostring(err or "")
    if s:find("logged in", 1, true) or s:find("未登录") or s:find("请先登录") then
        return "\n\n" .. _("该源需要登录：管理漫画源 → 已安装源 → 选中该源 →"
            .. "「账号登录」/「参数配置」。")
    end
    return ""
end

--- 源站/网络抛出的原文（`TLS 握手失败: wantread`、`解析到 0 个条目: URL`）
--- 对用户没有指导性，而这两类的处置方式完全不同：前者多半站点已失效，
--- 后者是站点活着但规则没落地。各补一句下一步（2026-09-24 移植包 v1.0.1
--- 真机实测：31 个源里 9 个站点不通、13 个源生成时没写卡片选择器）。
local function errHint(err)
    local s = tostring(err or "")
    -- 登录问题由 loginHint 负责，别把两条指引叠在一起
    if s:find("logged in", 1, true) or s:find("未登录", 1, true)
        or s:find("请先登录", 1, true) then
        return ""
    end
    if s:find("握手失败", 1, true) or s:find("wantread", 1, true)
        or s:find("请求失败", 1, true) or s:find("timed out", 1, true)
        or s:find("closed", 1, true) or s:find("refused", 1, true) then
        return "\n\n" .. _("站点没有响应：这个源多半已经失效或太慢（换代理也一样）。"
            .. "请先用别的源；若所有源都失败，再检查 设置 → 网络 → 代理。")
    end
    if s:find("0 个条目", 1, true) or s:find("未解析到", 1, true) then
        return "\n\n" .. _("站点有响应，但按源规则没解析到内容：源文件的选择器缺失"
            .. "或站点已改版，需要在移植流水线里补规则，插件侧无法修。")
    end
    return ""
end

--- 转义 JS 字符串字面量（与 jshost.jsStringEscape 同规则）
local function jesc(s)
    return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"')
        :gsub("\n", "\\n"):gsub("\r", "\\r"))
end

--- eval JSON 结果并解码。返回 (value|nil, err)
function Browser:_evalJSON(code)
    if not self.engine then
        return nil, "引擎不可用（Android 引擎需随 APK 分发；源列表/管理不受影响）"
    end
    local ok, res = self.engine:eval(code)
    if not ok then return nil, tostring(res) end
    if res == nil or res == "undefined" or res == "null" then
        return nil
    end
    local okj, J = pcall(require, "json")
    if not okj or not J then return nil, "json module unavailable" end
    local okd, v = pcall(function() return J.decode(res) end)
    if not okd then return nil, "bad JSON: " .. tostring(res) end
    return JsHost.stripNulls(v)
end

-- 【R2 独立评估】源方法的 promise 语义 + JS 原生 Map/Set 序列化：
-- JSON.stringify(new Map(...)) === "{}"——baozi/copy_manga 的 chapters 是
-- Map，普通 stringify 会把章节全部丢光。ser() 递归把 Map→对象、
-- Set→数组、函数丢弃、循环截断，再交给 JSON.stringify。
local AWAIT_SNIPPET = [[
(() => {
  const ser = (v, d) => {
    if (v === undefined) return undefined;
    if (v === null) return null;
    if (typeof v === "function") return undefined;
    const tn = Object.prototype.toString.call(v);
    if (tn === "[object Map]") {
      if (d > 8) return null;
      const o = {};
      for (const [k, x] of v) { const s = ser(x, d + 1);
        if (s !== undefined) o[String(k)] = s; }
      return o;
    }
    if (tn === "[object Set]") { if (d > 8) return null;
      return Array.from(v, (e) => ser(e, d + 1)); }
    if (tn === "[object ArrayBuffer]" ||
        (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView(v)))
      return "[binary]";
    if (Array.isArray(v)) { if (d > 8) return null;
      return v.map((e) => { const s = ser(e, d + 1);
        return s === undefined ? null : s; }); }
    if (typeof v === "object") {
      if (d > 8) return null;
      if (typeof v.then === "function") return { __unresolved_promise: true };
      const o = {};
      for (const k in v) { const s = ser(v[k], d + 1);
        if (s !== undefined) o[k] = s; }
      return o;
    }
    return v;
  };
  const enc = (x) => {
    try { return JSON.stringify(ser(x, 0)); }
    catch (e) { return '{"__error":"serialize: " + String(e)}'; }
  };
  globalThis.__ezv_ret = undefined;
  const out = (j) => { globalThis.__ezv_ret = j; };
  const s = ComicSource.sources["%s"];
  if (!s) return out(enc({ __error: "source not installed" }));
  const f = %s;
  let r;
  const errStr = (e) => {
    // quickjs 的 TypeError.message 只有 "not a function" 这类无位置信息，
    // 真机 R5 排查被迫靠 logcat 反推。有 stack 就带上（截断，弹窗可读）。
    const m = String((e && (e.message || e)) || e);
    const st = e && e.stack;
    if (!st || typeof st !== "string") return m;
    const frames = st.split("\n").slice(1, 4).join(" | ");
    return frames ? m + " @ " + frames.slice(0, 200) : m;
  };
  if (typeof f === "function") {
    try { r = f.apply(s, %s); }
    catch (e) {
      return out(enc({ __error: errStr(e) })); }
  } else if (f === undefined) {
    return out(enc({ __error: "missing %s" }));
  } else {
    r = f;                          // 静态属性（category/search 声明等）
  }
  if (r && typeof r.then === "function") {
    out('{"__pending":true}');
    r.then((v) => out(enc({ value: v })),
           (e) => out(enc({ __error: errStr(e) })));
  } else {
    out(enc({ value: r === undefined ? null : r }));
  }
})()
]]

--- 把已安装源注册进引擎（ComicSource.sources[jsKey]）。
--- 【R3 真机】此前无人调用 jshost:registerSource，引擎侧 sources 表恒空 →
--- 每次 eval 都走 "source not installed"。纯 Lua 的源管理只落盘不注册，
--- 浏览侧必须惰性注册；同 key 重装由 main.lua 清 self._registered 触发重载。
--- 返回 (jsKey|nil, err)：jsKey = 源文件自报的 key，可能与清单 key 不同，
--- 后续 eval 必须用它索引 ComicSource.sources。
function Browser:_ensureSourceLoaded(key)
    if not self.engine then
        return nil, "引擎不可用（Android 引擎需随 APK 分发；源列表/管理不受影响）"
    end
    self._registered = self._registered or {}
    if self._registered[key] then return self._registered[key] end
    local code = self.sources and self.sources:readSource(key)
    if not code then
        return nil, _("源文件读取失败，请重新安装该源")
    end
    local ok, res = self.engine:registerSource(code)
    if not ok then return nil, tostring(res) end
    local jsKey = (type(res) == "table" and res.key) or key
    self._registered[key] = jsKey
    return jsKey
end

--- 源在磁盘上被替换/删除后作废惰性注册（下次访问重新 readSource）
function Browser:invalidateSource(key)
    if self._registered then self._registered[key] = nil end
    -- 章节表同理：源换了版本，缓存里的章节 id 可能整体失效
    if self._chapter_cache then
        local prefix = key .. "\1"
        for ck in pairs(self._chapter_cache) do
            if ck:sub(1, #prefix) == prefix then self._chapter_cache[ck] = nil end
        end
    end
end

--- 成员路径 → JS 可选链表达式。中间成员缺失时得 undefined 而非 TypeError
--- （可选链 quickjs-ng 支持，源 JS 本身大量使用）。
---   "comic.loadInfo" → s?.comic?.loadInfo
---   "explore.0.load" → s?.explore?.[0]?.load
--- 数字段是**数组下标**，不能写成 `.0`（JS 语法错），必须 `?.[0]`——发现
--- (explore) 列表项就是按下标定位的（见 showSourceHome）。
local function memberChain(path)
    local chain = "s"
    for seg in (path .. "."):gmatch("([^%.]+)%.") do
        if seg:match("^%d+$") then
            chain = chain .. ("?.[%s]"):format(seg)
        else
            chain = chain .. "?." .. seg
        end
    end
    return chain
end

--- 单测直接检这条拼装（同 jshost.normalizeSourceJs 的做法）：拼错一个字符
--- 就是整批源打不开，且错在 JS 侧、Lua 侧看不见。
Browser.memberChain = memberChain

--- 调用源方法/属性并取回结果（同步值、async promise 统一处理）。
--- path 形如 "category" / "search.load" / "comic.loadInfo" / "explore.0.load"。
--- argsJson 为 JSON 数组字面量（可 nil）。返回 (value|nil, err)
function Browser:_awaitSource(key, path, argsJson)
    local jsKey, lerr = self:_ensureSourceLoaded(key)
    if not jsKey then return nil, lerr end
    local chain = memberChain(path)
    local code = AWAIT_SNIPPET:format(jesc(jsKey), chain,
        argsJson or "[]", path)
    -- engine:eval 内部：JS_Eval → 同步泵排空微任务（promise 兑现）
    local ok, err = self.engine:eval(code)
    if not ok then return nil, tostring(err) end
    local ok2, res = self.engine:eval("globalThis.__ezv_ret")
    if not ok2 then return nil, tostring(res) end
    if res == nil or res == "undefined" then
        return nil, "no result"
    end
    local okj, J = pcall(require, "json")
    if not okj or not J then return nil, "json module unavailable" end
    local okd, v = pcall(function() return J.decode(res) end)
    if not okd then
        logger.warn("ezvenera source bad JSON:", key, path,
            tostring(res):sub(1, 200))
        return nil, "bad JSON: " .. tostring(res)
    end
    if type(v) ~= "table" then return nil, "bad result shape" end
    if v.__pending then
        return nil, "异步任务未兑现（源内 promise 悬挂或泵上限截断）"
    end
    if v.__error then
        -- 源抛出的原文（含 errStr 带来的 JS 栈）必须落 logcat：弹窗只截前
        -- 若干字符，而"加载失败"这类无信息文案背后是 URL/状态码问题
        logger.warn("ezvenera source error:", key, path,
            tostring(v.__error):sub(1, 300))
        return nil, tostring(v.__error)
    end
    return v.value
end

--- 探测源成员是否存在（可选方法如 comic.onImageLoad）
function Browser:_hasMember(key, path)
    local jsKey = self:_ensureSourceLoaded(key)
    if not jsKey then return false end
    local v, _ = self:_evalJSON(('(()=>{ const s = ComicSource.sources["%s"];'
        .. ' const p = "%s".split("."); let o = s;'
        .. ' for (const k of p) { if (o == null) break; o = o[k]; }'
        .. ' return JSON.stringify(o !== undefined); })()')
        :format(jesc(jsKey), path))
    return v == true
end

--- 统一导航菜单构造（审查报告 §10 O1/O2，2026-09-24）。
--- O1：标题栏左键 = 返回箭头。KOReader 仅在设置 title_bar_left_icon 时才渲染
---     左键（menu.lua:737），回调留给调用方（menu.lua:1568）——这里统一为
---     "关当前层 = 返回上一级"。
--- O2：盖栈不拆栈——调用方的 onMenuSelect **不得**再 UIManager:close(menu_self)，
---     直接 show 下一层；左键与系统返回键（menu.lua:986 Back→onClose）同为
---     逐层返回，父层保持可见可回。
--- O3'：× 与返回键同走 onClose（TitleBar close_callback 硬连 onClose，
---     menu.lua:743，无法单独劫持），故 × = 逐层返回；在根层（源列表）关闭
---     即退出插件。级联退出不再单独实现——语义等价且更可预期。
function Browser:_navMenu(o)
    return Menu:new{
        title = o.title,
        subtitle = o.subtitle,
        item_table = o.item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "chevron.left",
        onLeftButtonTap = function(this)
            UIManager:close(this)
        end,
        onMenuSelect = o.onMenuSelect,
    }
end

--- 面包屑标题（§10 O4）："源名 › 叶子位置"。源 key → 源名映射惰性建一次。
--- sources 未注入（测试桩/降级环境）时直接用 key，不视为错误。
function Browser:_crumbTitle(key, leaf)
    if not self._source_names and self.sources and self.sources.listInstalled then
        self._source_names = {}
        for _, e in ipairs(self.sources:listInstalled() or {}) do
            self._source_names[e.key] = e.name
        end
    end
    local name = (self._source_names and self._source_names[key]) or key
    if leaf then
        return tostring(name) .. " › " .. tostring(leaf)
    end
    return tostring(name)
end

-- ---------- 层级 1：源列表 ----------

function Browser:showSourceList()
    local inst = self.sources:listInstalled()
    if #inst == 0 then
        self.infoMessage(_("没有已安装的漫画源。\n请先用「管理漫画源」从索引安装。"))
        return
    end
    local item_table = {}
    for _, e in ipairs(inst) do
        table.insert(item_table, {
            text = e.name or e.key,
            mandatory = e.version,
            key = e.key,
        })
    end
    local menu = self:_navMenu{
        title = _("EZVenera 漫画源"),
        item_table = item_table,
        onMenuSelect = function(menu_self, item)
            -- 盖栈：源主页压在本层之上，返回箭头/系统返回键回到源列表
            self:_guard(_("源主页"), function()
                self:showSourceHome(item.key)
            end)
        end,
    }
    UIManager:show(menu)
end

-- ---------- 层级 2：源主页（分类 + 搜索） ----------
-- 【R2 独立评估 + 真机 node 实测】EZVenera 源没有 navigation 成员（旧代码调
-- navigation 永远拿 missing 并被吞掉）。真实契约是：
--   category = { title, parts = [ { name, type, categories[],
--              categoryParams?, itemType? } ] }
-- `parts` 是**分组**（包子 7 组、拷贝 2 组、再漫画 2 组），categories 规范是
-- 扁平字符串数组（+平行的 categoryParams）；v1.0.1 移植包改成了
-- `{label,target}` 对象数组，两种都要吃（见下方循环）。旧代码直读
-- `category.categories` 恒为 nil → 主页只剩「搜索」一项。

--- 打开一个分类条目：itemType=="search" 当关键词搜，否则走 categoryComics
function Browser:_openCategoryItem(item)
    local key = item.key
    if item.is_search_item then
        local options = self:_defaultOptions(key, "search", "search")
        self:showResults(key, "search.load",
            { item.category, options }, 1, _("搜索: ") .. item.category)
        return
    end
    self:showCategory(key, item)
end

--- explore 数组 → 菜单项。prefix 为该项的成员路径（"explore" /
--- "explore.3.subExplores"），下标 1..n 与 JS 数组一致。
local function exploreItems(list, prefix, key)
    local out = {}
    for i, item in ipairs(list or {}) do
        if type(item) == "table" and item.title then
            local base = prefix .. "." .. i
            if item.type == "subExplores" or type(item.subExplores) == "table" then
                table.insert(out, {
                    text = tostring(item.title),
                    explore_sub = base .. ".subExplores",
                    key = key,
                })
            else
                table.insert(out, {
                    text = tostring(item.title),
                    explore_path = base .. ".load",
                    -- Venera 里 type 可省略（省略即单页列表）
                    explore_type = item.type or "comicList",
                    key = key,
                })
            end
        end
    end
    return out
end

--- 分区型发现数据 → [{title, comics}]。兼容三种真实写法：
---   { 分区名 = [Comic], … }        copy_manga singlePageWithMultiPart
---   { pages = [{title, comics}] }  pageCol
---   [Comic]                        comicList / 未知类型的兜底
--- 注：JSON 解进 Lua 表后**对象键的原始顺序丢失**，分区按标题排序呈现
--- （稳定优先于"跟源里一样"）。
local function exploreParts(data)
    local out = {}
    if type(data) ~= "table" then return out end
    if type(data.pages) == "table" then
        for _, p in ipairs(data.pages) do
            if type(p) == "table" and type(p.comics) == "table" then
                table.insert(out, {
                    title = tostring(p.title or p.context or _("分区")),
                    comics = p.comics,
                })
            end
        end
        if #out > 0 then return out end
    end
    local first = data[1]
    if type(first) == "table" and (first.title ~= nil or first.id ~= nil) then
        return { { title = _("全部"), comics = data } }
    end
    for k, v in pairs(data) do
        if type(k) == "string" and type(v) == "table" and #v > 0 then
            table.insert(out, { title = k, comics = v })
        end
    end
    table.sort(out, function(a, b) return a.title < b.title end)
    return out
end

function Browser:showSourceHome(key)
    if not self.engine then
        self.infoMessage(_("引擎不可用，无法浏览该源内容。\n源列表与源管理不受影响。"))
        return
    end
    -- 先过注册关：源文件本身读不进引擎（移植包里 21/31 是 JS 语法错误）时，
    -- 后面每次 _awaitSource 都会把同一条 SyntaxError 当成"分类读取失败"弹一遍，
    -- 用户看到的是莫名其妙的分类报错（2026-09-24 真机反馈）。在这里一次说清。
    local jsKey, loadErr = self:_ensureSourceLoaded(key)
    if not jsKey then
        self.infoMessage(_("该源无法加载：") .. tostring(loadErr))
        return
    end
    local item_table = {
        {
            text = _("搜索"),
            callback = function() self:showSearch(key) end,
        },
    }
    local n_cat, readErr = 0, nil
    local decl, err = self:_awaitSource(key, "category")
    if type(decl) == "table" then
        local parts = (type(decl.parts) == "table" and decl.parts)
            or (type(decl.categories) == "table"
                and { { categories = decl.categories,
                        categoryParams = decl.categoryParams,
                        itemType = decl.itemType } }
                or nil)
        for _, part in ipairs(parts or {}) do
            if type(part) == "table" and type(part.categories) == "table"
                    and #part.categories > 0 then
                local params = part.categoryParams or {}
                if part.name and part.name ~= "" then
                    table.insert(item_table, {
                        text = tostring(part.name), info_only = true,
                    })
                end
                for i, cat in ipairs(part.categories) do
                    local label, category, param = tostring(cat), nil, params[i]
                    if type(cat) == "table" then
                        -- 【2026-09-24 移植包 v1.0.1】Venera 契约的 categories 是
                        -- 字符串数组（+平行 categoryParams），但自动移植流水线产出
                        -- `{label, target:{page, attributes:{category, param}}}`。
                        -- 不吃这一形状的话 `tostring(cat)` 会渲染成 "table: 0x…"，
                        -- 而 param 取不到 → 源里 URL 退化成 baseUrl（点了没内容）。
                        label = cat.label or cat.name or cat.title or ""
                        local at = (type(cat.target) == "table")
                            and cat.target.attributes or nil
                        if type(at) == "table" then
                            category = at.category
                            param = at.param
                        end
                        category = category or cat.category or label
                        param = param or cat.param or cat.value or params[i]
                    end
                    label = tostring(label)
                    n_cat = n_cat + 1
                    table.insert(item_table, {
                        text = label,
                        category = tostring(category or label),
                        param = param,
                        -- itemType=="search" 的分类项当关键词搜；否则走分类
                        is_search_item = part.itemType == "search",
                        key = key,
                    })
                end
            end
        end
    elseif err and err:find("missing", 1, true) == nil then
        -- category 存在但读取失败才提示（missing 只是该源无分类声明）
        readErr = _("分类声明读取失败：") .. tostring(err)
    end
    -- ---------- 发现（explore） ----------
    -- 【2026-09-24 移植包两代实测】v1.0.0 的 31 个移植源**全部**只有 explore、
    -- 没有 category（logcat: `czmanga category missing category`）；重新生成的
    -- v1.0.1 反过来全部只有 category、没有 explore。两代都要能点进去有内容，
    -- 所以 category 与 explore 两条声明都读、都渲染。Venera 契约：
    --   explore = [ { title, type, load } ]
    --   multiPageComicList     load(page) → { comics, maxPage }  （picacg）
    --   comicList              load()     → [ Comic ]
    --   singlePageWithMultiPart load()    → { 分区名 = [ Comic ] }（copy_manga）
    --   pageCol                load(page) → { title, pages = [...] }
    --   subExplores            无 load，带子项数组（再点一层）
    local ex, exErr = self:_awaitSource(key, "explore")
    local n_exp = 0
    if type(ex) == "table" then
        for _, it in ipairs(exploreItems(ex, "explore", key)) do
            n_exp = n_exp + 1
            table.insert(item_table, it)
        end
    elseif exErr and exErr:find("missing", 1, true) == nil then
        readErr = readErr or (_("发现内容读取失败：") .. tostring(exErr))
    end
    if readErr then self.infoMessage(readErr) end
    if n_cat == 0 and n_exp == 0 then
        -- 什么都没声明：明说，别让菜单看起来像加载坏了
        table.insert(item_table, {
            text = _("（该源未声明分类/发现项，只能用搜索）"),
            info_only = true,
        })
    end
    local menu = self:_navMenu{
        title = self:_crumbTitle(key),
        item_table = item_table,
        onMenuSelect = function(menu_self, item)
            -- 分组标题行（info_only）没有对应内容：真机上点「主题」这类灰行
            -- 会先关掉整个菜单再什么也不做，用户以为源坏了。灰行直接忽略。
            if item.info_only then return end
            self:_guard(_("分类"), function()
                if item.callback then
                    item.callback()
                elseif item.explore_path or item.explore_sub then
                    self:_openExploreItem(key, item)
                elseif item.is_search_item or item.category then
                    self:_openCategoryItem(item)
                end
            end)
        end,
    }
    UIManager:show(menu)
end

--- 发现项被点：子项组开子菜单，其余交给 _openExplore
function Browser:_openExploreItem(key, item)
    if item.explore_sub then
        self:_showExploreSub(key, item.explore_sub, item.text)
    else
        self:_openExplore(key, item)
    end
end

--- 二级发现（subExplores）：同一套菜单渲染，路径前缀带上下标
function Browser:_showExploreSub(key, path, title)
    local list, err = self:_awaitSource(key, path, "[]")
    if not list then
        self.infoMessage(_("子项读取失败：") .. tostring(err))
        return
    end
    local items = exploreItems(list, path, key)
    if #items == 0 then
        self.infoMessage(_("该发现项没有内容"))
        return
    end
    local menu = self:_navMenu{
        title = self:_crumbTitle(key, title or key),
        item_table = items,
        onMenuSelect = function(menu_self, item)
            self:_guard(_("发现"), function()
                self:_openExploreItem(key, item)
            end)
        end,
    }
    UIManager:show(menu)
end

--- 打开一个发现项。分页/单页列表直接复用 showResults（下一页、进详情现成）；
--- 分区型（singlePageWithMultiPart / pageCol）先取数据再按分区下钻。
function Browser:_openExplore(key, item)
    local typ = item.explore_type
    if typ == "multiPageComicList" or typ == "comicList" then
        self:showResults(key, item.explore_path, {}, 1, item.text)
        return
    end
    local data, err = self:_awaitSource(key, item.explore_path, "[]")
    if type(data) ~= "table" then
        self.infoMessage(_("加载失败：") .. tostring(err)
            .. loginHint(err) .. errHint(err))
        return
    end
    local parts = exploreParts(data)
    if #parts == 0 then
        self.infoMessage(_("无结果"))
        return
    end
    if #parts == 1 then
        self:showComicArrayMenu(item.text, key, parts[1].comics)
        return
    end
    local item_table = {}
    for _, p in ipairs(parts) do
        table.insert(item_table, {
            text = p.title,
            mandatory = ("%d"):format(#p.comics),
            part = p,
        })
    end
    local menu = self:_navMenu{
        title = self:_crumbTitle(key, item.text),
        item_table = item_table,
        onMenuSelect = function(menu_self, it)
            self:_guard(_("发现"), function()
                self:showComicArrayMenu(it.part.title .. " · " .. item.text,
                    key, it.part.comics)
            end)
        end,
    }
    UIManager:show(menu)
end

--- 静态漫画数组 → 列表菜单（分区型发现用；无分页，点击直接进详情）
function Browser:showComicArrayMenu(title, key, comics)
    local item_table = {}
    for _, c in ipairs(comics or {}) do
        if type(c) == "table" and (c.title or c.id) then
            table.insert(item_table, {
                text = c.title or c.id,
                mandatory = (c.stars and tostring(c.stars)) or nil,
                comic = c,
            })
        end
    end
    if #item_table == 0 then
        self.infoMessage(_("无结果"))
        return
    end
    local menu = self:_navMenu{
        title = self:_crumbTitle(key,
            tostring(title) .. (" · %d"):format(#item_table)),
        item_table = item_table,
        onMenuSelect = function(menu_self, item)
            self:_guard(_("详情"), function()
                self:showDetail(key, item.comic)
            end)
        end,
    }
    UIManager:show(menu)
end

--- 该 optionList 分组在当前上下文（分类名或 "search"）是否可见。
--- Venera 语义：notShowWhen 命中即隐藏；showWhen 为字符串时须相等，
--- 为数组时须包含当前项；缺省/空 = 不限制。
local function optionGroupVisible(group, ctx)
    local hide = group.notShowWhen
    if type(hide) == "string" and hide ~= "" and hide == ctx then
        return false
    end
    local show = group.showWhen
    if type(show) == "string" then
        return show == "" or show == "ALL" or show == ctx
    end
    if type(show) == "table" then
        if next(show) == nil then return true end
        for _, v in ipairs(show) do
            if v == ctx then return true end
        end
        return false
    end
    return true
end

--- 单组 → 选中值；返回 nil 表示整组跳过（后续组的位置随之前移）
local function optionGroupValue(group, ctx)
    local list
    if type(group) == "table" then
        if not optionGroupVisible(group, ctx) then return nil end
        list = group.options or group.values
    else
        list = group
    end
    local first
    if type(list) == "table" then
        first = list[1]                      -- Venera 默认选中每组第一项
    elseif type(list) == "string" then
        first = list                         -- 扁平 optionList：整串即一项
    end
    if type(first) ~= "string" then return "" end
    -- "value-label"：value = 首个 '-' 之前的整段。注意 `*` 属于 value，
    -- 不是默认项标记（copy_manga.js:638 比的是 "*all"，:635 把
    -- "*datetime_updated" 换成 "-datetime_updated"）——剥掉就选错值。
    return first:match("^[^%-]*")
end

--- 源声明的 optionList 默认选择，**按当前上下文过滤分组**。
--- methodPath: "search" | "categoryComics"；ctx: 分类名或 "search"。
--- 【R7 代码实证】过滤不可省：源里按位置取 options[0..n]
--- （copy_manga.js:626/633、zaimanhua.js:224），而 optionList 按 showWhen
--- 分组。排行榜不过滤 → 传进去的是「分类组」的默认值，rank 参数直接
--- 错位（zaimanhua.js:210 更把整个数组拼进 URL）。
function Browser:_defaultOptions(key, methodPath, ctx)
    local ol = self:_awaitSource(key, methodPath .. ".optionList")
    local out = {}
    if type(ol) ~= "table" then return out end
    for _, group in ipairs(ol) do
        local v = optionGroupValue(group, ctx or "")
        if v ~= nil then table.insert(out, v) end
    end
    return out
end

-- ---------- 层级 3a：搜索 ----------
-- 【R2 独立评估】源签名为 search.load(keyword, options, page)——三参；
-- 旧代码只传 (keyword)。options = 选中项 key 数组（默认 optionList 首项）。

function Browser:showSearch(key)
    local InputDialog = require("ui/widget/inputdialog")
    local options = self:_defaultOptions(key, "search", "search")
    local dialog
    local function runSearch(kw)
        if not kw or kw == "" then return end
        UIManager:close(dialog)
        self:showResults(key, "search.load", { kw, options }, 1,
            _("搜索: ") .. kw)
    end
    dialog = InputDialog:new{
        title = _("搜索漫画"),
        input = "",
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
            {
                {
                    text = _("搜索"),
                    is_enter_default = true,
                    callback = function()
                        self:_guard(_("搜索"), function()
                            runSearch(dialog:getInputText())
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ---------- 层级 3b：分类（含 options） ----------

function Browser:showCategory(key, item)
    -- categoryComics.load(category, param, options, page)
    local options = self:_defaultOptions(key, "categoryComics", item.category)
    self:showResults(key, "categoryComics.load",
        { item.category, item.param or "", options }, 1, item.text)
end

--- 【R9 真机闪退收口】凡由菜单回调、widget 回调、scheduleIn 回调或 metamethod
--- 直接调用的入口，都必须自己收住错误并转成用户可见提示：错误冒到 KOReader
--- 主循环即变成整应用闪退（用户看不到任何原因）。
--- 【订正 2026-09-23】早前把 tombstone 归因为"死在 luaL_traceback 里"，那是
--- ELF 段偏移算错导致的误判（tombstone 的 pc 要 +0x1a000 才是 vaddr）。重算后
--- 三次崩溃的 #00 同为 libluajit vaddr 0x87258 的 `STR x12,[x10,#16]`，x10 =
--- 0x0000dc0800000402（非指针形状）→ 是 VM 内部拿到被写坏的指针，与 traceback
--- 无关。根因排查进行中（任务 #16 / selftest.lua），这里的错误收口本身仍然保留。
local function guardCall(label, fn)
    local ok, err = xpcall(fn, function(msg) return tostring(msg) end)
    if not ok then
        logger.warn("ezvenera: " .. label .. " 内部错误:", err)
    end
    return ok, err
end

function Browser:_guard(label, fn)
    local ok, err = guardCall(label, fn)
    if not ok then
        self.infoMessage(_("操作失败：") .. label .. "\n" .. tostring(err))
    end
end

--- 进度提示：自消失的 toast。InfoMessage 默认是模态框，会一直压在下一个
--- 界面之上直到用户点掉——真机表现为阅读器已经开好了，上面还盖着一个
--- "章节加载中…"。错误提示仍走模态（必须让用户看到）。
function Browser:progressMessage(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

-- ---------- 层级 4：结果列表（通用 comics 列表渲染） ----------

--- methodPath: "search.load" | "categoryComics.load" | "explore.<i>.load"
--- argsTable: 不含 page 的参数前缀（Lua 值，逐项 JSON 编码后拼接）
function Browser:showResults(key, methodPath, argsTable, page, title)
    self:progressMessage(_("加载中…"))
    local parts = {}
    for _, a in ipairs(argsTable) do
        local okj, J = pcall(require, "json")
        local s
        if type(a) == "table" and next(a) == nil then
            s = "[]"       -- 空 options：Venera 侧一律是数组（源里 .map 调用）
        elseif okj and J then
            local oke, enc = pcall(function() return J.encode(a) end)
            s = oke and enc or '"' .. jesc(tostring(a)) .. '"'
        else
            s = '"' .. jesc(tostring(a)) .. '"'
        end
        table.insert(parts, s)
    end
    table.insert(parts, tostring(page or 1))
    local res, err = self:_awaitSource(key, methodPath,
        "[" .. table.concat(parts, ",") .. "]")
    if not res then
        self.infoMessage(_("加载失败：") .. tostring(err) .. loginHint(err) .. errHint(err))
        return
    end
    if type(res) ~= "table" then
        -- 源返回 null / 字符串：直接 res.comics 取值会在 lightuserdata 上
        -- 索引而崩（KOReader 主循环里的 Lua error = 整应用闪退）
        self.infoMessage(_("该源返回了空数据（type=") .. type(res) .. "）")
        return
    end
    local comics = res.comics
    if type(comics) ~= "table" then
        -- explore 的 comicList / 部分源直接返回数组本身，没有 {comics=…} 包装
        comics = (#res > 0) and res or {}
    end
    local maxPage = tonumber(res.maxPage) or page or 1
    if #comics == 0 then
        self.infoMessage(_("无结果"))
        return
    end
    local item_table = {}
    for _, c in ipairs(comics) do
        table.insert(item_table, {
            text = c.title or c.id,
            mandatory = (c.stars and tostring(c.stars)) or nil,
            comic = c,
        })
    end
    if maxPage > (page or 1) then
        table.insert(item_table, {
            text = _("▶ 下一页"),
            nextPage = true,
        })
    end
    local menu = self:_navMenu{
        title = self:_crumbTitle(key, (title or key)
            .. (" · %d/%s"):format(page or 1, tostring(maxPage))),
        item_table = item_table,
        onMenuSelect = function(menu_self, item)
            self:_guard(_("结果列表"), function()
                if item.nextPage then
                    -- 盖栈：下一页压在本页之上，返回箭头回到上一页（历史语义）
                    self:showResults(key, methodPath, argsTable,
                        (page or 1) + 1, title)
                elseif item.comic then
                    -- 盖栈：详情压在结果页之上，返回箭头回到本页
                    self:showDetail(key, item.comic)
                end
            end)
        end,
    }
    UIManager:show(menu)
end

-- ---------- 层级 5：详情（章节列表） ----------

--- 章节 id 排序：数字 id 按数值（"10" 排在 "9" 之后），其余按字符串。
local function chapterCmp(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    return tostring(a) < tostring(b)
end

--- 章节表 → 有序数组 { {epId=, title=}, ... }。扁平 {id:title} 与分组
--- {group:{id:title}}（JS Map 已由 ser() 转成普通对象）两种形态都在这里收敛：
--- 详情、下载清单、阅读器的上下章/目录共用一份，排序规则不会走偏。
--- pairs() 的顺序不保证（真机同一本书两次顺序不同），所以组和章节都要显式排。
local function flattenChapters(chapters)
    local rows, groups = {}, {}
    for k, v in pairs(chapters or {}) do
        if type(v) == "table" then
            local ids = {}
            for id in pairs(v) do ids[#ids + 1] = id end
            table.sort(ids, chapterCmp)
            local g = { label = tostring(k), rows = {} }
            for _, id in ipairs(ids) do
                g.rows[#g.rows + 1] = {
                    epId = id, title = tostring(k) .. " / " .. tostring(v[id]),
                }
            end
            groups[#groups + 1] = g
        else
            rows[#rows + 1] = { epId = k, title = tostring(v) }
        end
    end
    if #groups > 0 then
        table.sort(groups, function(a, b) return a.label < b.label end)
        for _, g in ipairs(groups) do
            for _, r in ipairs(g.rows) do rows[#rows + 1] = r end
        end
    else
        table.sort(rows, function(a, b) return chapterCmp(a.epId, b.epId) end)
    end
    return rows
end

--- 章节表缓存：详情打开时就填，阅读器的上下章/目录直接命中（零网络）。
function Browser:_cacheChapters(key, comicId, rows)
    self._chapter_cache = self._chapter_cache or {}
    self._chapter_cache[key .. "\1" .. tostring(comicId)] = rows
    return rows
end

--- 取一本书的章节表（阅读器侧：没进过详情才会真发源调用）。
function Browser:_chapterList(key, comicId)
    local ck = key .. "\1" .. tostring(comicId)
    local hit = self._chapter_cache and self._chapter_cache[ck]
    if hit then return hit end
    local res, err = self:_awaitSource(key, "comic.loadInfo",
        '[' .. '"' .. jesc(comicId) .. '"' .. ']')
    if not res then
        return nil, _("章节列表加载失败：") .. tostring(err) .. loginHint(err)
    end
    return self:_cacheChapters(key, comicId, flattenChapters(res.chapters))
end

function Browser:showDetail(key, comic)
    self:progressMessage(_("加载详情…"))
    local res, err = self:_awaitSource(key, "comic.loadInfo",
        '[' .. '"' .. jesc(comic.id) .. '"' .. ']')
    if not res then
        self.infoMessage(_("详情加载失败：") .. tostring(err) .. loginHint(err) .. errHint(err))
        return
    end
    local details = res
    local bookTitle = details.title or comic.title
    if self.library then
        -- 打开详情即算一条阅读记录；章节由 showReader 覆盖进同一条
        self.library:recordRead({ key = key, comicId = comic.id,
            title = bookTitle })
    end
    local item_table = {}
    -- 章节：扁平 {id:title} 或分组 {group:{id:title}}；排序规则收敛在
    -- flattenChapters，详情 / 下载清单 / 阅读器切章共用同一份
    local chapters = flattenChapters(details.chapters)
    self:_cacheChapters(key, comic.id, chapters)
    if details.title then
        table.insert(item_table, {
            text = _("◆ ") .. (details.title or comic.title),
            info_only = true,
        })
    end
    local chapter_rows = {}   -- 详情已取到的章节表，离线下载清单直接复用
    for _, ch in ipairs(chapters) do
        table.insert(item_table, {
            text = ch.title,
            mandatory = tostring(ch.epId),
            comicId = comic.id,
            epId = ch.epId,
        })
        table.insert(chapter_rows, { comicId = comic.id, epId = ch.epId,
            title = ch.title })
    end
    if #chapter_rows > 0 then
        -- 收藏插到 1 位时会把它挤到第 2 行：顶部两行固定是「收藏 / 下载」
        table.insert(item_table, 1, {
            text = _("下载章节（离线阅读）"),
            downloadMgr = true,
        })
    end
    if self.library then
        local isFav = self.library:isFavorite(key, comic.id)
        table.insert(item_table, 1, {
            text = isFav and _("★ 已收藏（点击取消）") or _("☆ 收藏本书"),
            favToggle = true,
        })
    end
    local menu = self:_navMenu{
        title = self:_crumbTitle(key, bookTitle or key),
        item_table = item_table,
        onMenuSelect = function(menu_self, item)
            self:_guard(_("章节"), function()
                if item.favToggle then
                    local now = self.library:toggleFavorite({
                        key = key, comicId = comic.id, title = bookTitle,
                    })
                    -- 不重建菜单（重建要重取详情=又一次网络请求）；用自消失
                    -- 提示确认结果，标签在下次进入时刷新。
                    item.text = now and _("★ 已收藏（点击取消）")
                        or _("☆ 收藏本书")
                    self:progressMessage(now and _("已加入收藏夹")
                        or _("已取消收藏"))
                elseif item.downloadMgr then
                    self:showChapterDownloads(key, bookTitle, chapter_rows)
                elseif item.epId then
                    -- 【返回】章节菜单不关：阅读器盖在其上，关掉阅读器即回到
                    -- 章节列表。此前先 close 再开阅读器，栈被拆掉，用户只剩
                    -- 【关闭】一个出口（真机反馈"无返回按钮"）。
                    self:showReader(key, item.comicId, item.epId,
                        bookTitle, item.text)
                end
            end)
        end,
    }
    UIManager:show(menu)
end

-- ---------- 层级 5.5：离线下载（章节落盘 / 缓存管理） ----------
-- 为什么自己做：Venera 契约里"下载"由宿主 App（Flutter Downloader）实现，JS 源
-- 只给 images URL 列表。本移植的 HTTP 通道是 netclient（ADR-003 插件自带代理），
-- 所以取字节、落盘、清理也只能我们自己做 → runtime/downloader.lua。

--- 字节数 → 人话。真机 v2026.07.1 的 util.getFormattedSize 输出的是千分位
--- 原始字节（截图实测 "1,683,200"），可读性反而更差 → 只用本地格式化。
local function fmtSize(n)
    n = math.floor(n or 0)
    if n >= 1048576 then return (("%.1f MB"):format(n / 1048576)) end
    if n >= 1024 then return (("%d KB"):format(math.floor(n / 1024))) end
    return (("%d B"):format(n))
end

--- 取一话的页表 + 公共头。阅读与下载共用一条路：两处各写一遍 onImageLoad
--- 的 headers 合并，迟早不一致。
--- 返回 (images, base_headers) 或 (nil, nil, err)；err 已是给用户看的话。
function Browser:_loadEpImages(key, comicId, epId)
    local base
    -- onImageLoad 为可选声明（baozi/copy_manga 无）：仅存在时取 headers
    if self:_hasMember(key, "comic.onImageLoad") then
        local c, err = self:_awaitSource(key, "comic.onImageLoad",
            '[' .. '"' .. jesc(comicId) .. '","' .. jesc(epId) .. '"' .. ']')
        if not c then
            return nil, nil, _("图片配置加载失败：") .. tostring(err) .. loginHint(err)
        end
        base = type(c.headers) == "table" and c.headers or nil
    end
    local ep, err2 = self:_awaitSource(key, "comic.loadEp",
        '[' .. '"' .. jesc(comicId) .. '","' .. jesc(epId) .. '"' .. ']')
    if not ep or type(ep) ~= "table" then
        return nil, nil, _("章节加载失败：") .. tostring(err2 or "no images")
            .. loginHint(err2)
    end
    -- 两种 Venera 返回形态：ChapterImages{ images: [...] } 或纯 URL 数组
    local images = type(ep.images) == "table" and ep.images or ep
    if images[1] == nil then
        return nil, nil, _("章节加载失败：源未返回任何图片")
    end
    return images, base
end

local function nowSec()
    local ok, ffiutil = pcall(require, "ffi/util")
    local gt = ok and type(ffiutil) == "table" and ffiutil.gettime or nil
    if gt then
        local tok, t = pcall(gt)
        if tok and type(t) == "number" then return t end
    end
    return os.time()
end

--- 取一张图的字节：合并公共头 + 单页头 + cookie jar + 插件代理（ADR-003），
--- 失败原地重试 2 次。返回 (body, resp_headers) 或 (nil, err)。
--- opts（可选）：{ attempts, timeout_block, timeout_total, budget }。
--- budget 是**整次调用的墙钟预算**（默认 4.5s）：预算用尽就不再原地重试。
--- 阅读器/下载器都在主循环里跑，一次调用超过 5s 安卓就弹「无响应」；
--- 快速失败（403/5xx/拒连）照样重试，超时型的失败只撞一次。理由详见
--- showReader 的 IMG_OPTS 注释与 netclient.new 的 default_timeout_block。
function Browser:fetchImageBytes(url, base_headers, page_headers, opts)
    if type(url) ~= "string" or url == "" then return nil, "no url" end
    opts = opts or {}
    local netclient = self.netclient
    if not netclient then return nil, "no request channel" end
    local h = {}
    if type(base_headers) == "table" then
        for k2, v2 in pairs(base_headers) do h[k2] = v2 end
    end
    if type(page_headers) == "table" then
        for k2, v2 in pairs(page_headers) do h[k2] = v2 end
    end
    -- 与 bridge 的 http 通道同构：代理设置 + cookie jar 必须一并作用于图片
    -- 请求，否则开了代理就是直连失败、需要会话 cookie 的源全是 403。
    if self.cookies then
        local jarh = self.cookies:headerFor(url)
        if jarh then
            local ex = h["cookie"] or h["Cookie"]
            h["Cookie"] = ex and (ex .. "; " .. jarh) or jarh
            h["cookie"] = nil
        end
    end
    local proxy = nil
    if self.settings then
        proxy = (self.settings:isProxyEnabled())
            and self.settings:getProxyURL() or ""
    end
    -- 【真机 2026-09-24 baozi】代理节点对**部分主机**是不通的（CONNECT 回
    -- 200 之后一个 TLS 字节都不回），而设备直连同一主机 2s 拿全图。这种主机
    -- 经代理撞一次传输层失败后就降级为直连（只影响这台主机，代理配置本身不动；
    -- 每次请求的代理仍由插件显式指定，ADR-003 不破）。
    local host = url:match("^[%a]+://[^/]+")
    if proxy ~= nil and proxy ~= "" and self._direct_hosts
            and self._direct_hosts[host] then
        proxy = ""
    end
    -- onLoadFailed 重试链（Venera 语义 5 次 → 冷路径收敛为 2 次，且受预算约束）
    local last
    local t0 = nowSec()
    local attempts = opts.attempts or 2
    for i = 1, attempts do
        if i > 1 and (nowSec() - t0) > (opts.budget or 4.5) - 0.5 then
            break
        end
        local ok, resp = pcall(function()
            return netclient:request({ url = url, method = "GET",
                headers = h, proxy = proxy,
                timeout_block = opts.timeout_block,
                timeout_total = opts.timeout_total })
        end)
        if not ok then
            last = tostring(resp)
        elseif type(resp) ~= "table" then
            last = "bad response"
        elseif resp.status ~= 200 or type(resp.body) ~= "string"
                or resp.body == "" then
            last = "status " .. tostring(resp.status or resp.error)
            if resp.status == nil and type(proxy) == "string" and proxy ~= "" then
                self._direct_hosts = self._direct_hosts or {}
                if not self._direct_hosts[host] then
                    self._direct_hosts[host] = true
                    logger.warn("ezvenera: proxy broken for", host,
                        "→ 本会话该主机改走直连")
                end
            end
        else
            return resp.body, resp.headers
        end
    end
    logger.warn("ezvenera: image fetch failed:", tostring(url:match("^[%a]+://[^/]+")),
        last)
    return nil, last
end

--- 离线下载器（懒建，一个 Browser 实例共用一份）。
function Browser:getDownloader()
    if self._downloader then return self._downloader end
    if self.downloader then
        self._downloader = self.downloader
        return self._downloader
    end
    local basedir = self.downloads_dir
    if not basedir then
        local ok, DataStorage = pcall(require, "datastorage")
        if ok and DataStorage then
            basedir = DataStorage:getDataDir() .. "/ezvenera/downloads"
        else
            basedir = "ezvenera/downloads"
        end
    end
    local self2 = self
    self._downloader = Downloader.new{
        basedir = basedir,
        request = function(url, headers)
            -- 下载器每拍一页，同样跑在主循环里：给紧超时，保留 2 次尝试，
            -- 整次由 fetchImageBytes 的 budget 封顶（见其注释）。
            local data, hdrs, err = self2:fetchImageBytes(url, nil, headers,
                { timeout_block = 3, timeout_total = 6 })
            if not data then return { status = 0, error = err or hdrs } end
            return { status = 200, body = data, headers = hdrs }
        end,
    }
    return self._downloader
end

--- 章节下载清单（从详情已取到的章节表生成，不再请求网络）。
--- 每行都是普通菜单项 —— ADR-005：不依赖 hold。
function Browser:showChapterDownloads(key, bookTitle, chapters)
    local dl = self:getDownloader()
    local item_table = {}
    for _, ch in ipairs(chapters) do
        local man = dl:manifestOf(key, ch.comicId, ch.epId)
        table.insert(item_table, {
            text = (man and "◆ " or "○ ") .. ch.title,
            mandatory = man and (("%d 页 · %s"):format(#man.pages, fmtSize(man.bytes)))
                or tostring(ch.epId),
            dlComicId = ch.comicId, dlEpId = ch.epId, dlTitle = ch.title,
        })
    end
    if #item_table == 0 then
        self.infoMessage(_("没有可下载的章节"))
        return
    end
    local menu = self:_navMenu{
        title = self:_crumbTitle(key,
            _("下载章节 · ") .. (bookTitle or key)),
        item_table = item_table,
        onMenuSelect = function(menu_self, item)
            self:_guard(_("下载章节"), function()
                if not item.dlEpId then return end
                -- 下载是异步的（逐页节拍）：结果只在 on_done 里回到这一行
                self:downloadChapter(key, item.dlComicId, item.dlEpId,
                    bookTitle, item.dlTitle, function(ok, info)
                        if not ok or not info then return end
                        item.text = "◆ " .. tostring(item.dlTitle)
                        item.mandatory = (("%s · %s"):format(
                            fmtSize(info.bytes), _("已下载")))
                        pcall(function()
                            menu_self:switchItemTable(nil, item_table, -1)
                        end)
                    end)
            end)
        end,
    }
    UIManager:show(menu)
end

--- 下载一话，逐页推进不冻结界面。
--- KOReader 是单线程 UI：一话 40-60 页 × 1-2s 就是几十秒，一次性下完会让界面
--- 完全没有响应（连取消都点不到）。所以每拍只下 1 页，两拍之间事件循环会跑。
--- 挂了进度对话框即走异步：本函数立刻返回 nil（结果只经 on_done）；没有调度器
--- 的环境（单测）同步跑完，返回值与 on_done 一致。
function Browser:downloadChapter(key, comicId, epId, bookTitle, chapterTitle, on_done)
    local dl = self:getDownloader()
    local have = dl:manifestOf(key, comicId, epId)
    if have then
        self:progressMessage((_("本章已在本地：%d 页 · %s"))
            :format(#have.pages, fmtSize(have.bytes)))
        if on_done then on_done(true, have) end
        return true, have
    end
    local images, base, err = self:_loadEpImages(key, comicId, epId)
    if not images then
        self.infoMessage(err or _("章节加载失败"))
        if on_done then on_done(false, err) end
        return false, err
    end
    local state = { finished = false, cancelled = false, dialog = nil }
    local job, berr = dl:begin{
        key = key, comicId = comicId, epId = epId,
        comicTitle = bookTitle, chapterTitle = chapterTitle,
        images = images, base_headers = base,
        on_progress = function(done)
            if state.dialog then
                pcall(function() state.dialog:reportProgress(done) end)
            end
            -- 下载中点对话框的关闭即中止：回 false 让 downloader 清掉半截文件
            return not state.cancelled
        end,
    }
    if not job then
        self.infoMessage(_("下载失败：") .. tostring(berr))
        if on_done then on_done(false, berr) end
        return false, berr
    end

    local okpd, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
    if okpd and ProgressbarDialog and job.total and job.total > 0 then
        local okd, d = pcall(function()
            return ProgressbarDialog:new{
                title = _("下载章节"),
                subtitle = tostring(chapterTitle or bookTitle or ""),
                progress_max = job.total,
                refresh_time_seconds = 1,
                dismissable = true,
                dismiss_callback = function()
                    if not state.finished then state.cancelled = true end
                end,
            }
        end)
        if okd then
            state.dialog = d
            pcall(function() d:show() end)
        end
    end

    local out = {}
    local function stop(st, info)
        state.finished = true
        if state.dialog then
            pcall(function() state.dialog:close() end)
            state.dialog = nil
        end
        if st == "done" then
            out.ok, out.man = true, info
            self:progressMessage((_("已下载 %d 页 · %s"))
                :format(#info.pages, fmtSize(info.bytes)))
        else
            out.ok, out.err = false, tostring(info)
            if tostring(info) == "已取消" then
                self:progressMessage(_("已取消下载"))
            else
                self.infoMessage(_("下载失败：") .. tostring(info))
            end
        end
        if on_done then
            local okc, e = pcall(on_done, out.ok, out.ok and out.man or out.err)
            if not okc then logger.warn("ezvenera: 下载回调出错:", e) end
        end
    end
    local function stepOnce()
        if state.finished then return end
        guardCall(_("下载章节"), function()
            if state.cancelled then job.stopped = true end
            local st, info = dl:step(job)
            if st == "run" then
                -- 排不进节拍（测试环境/无调度器）就直接跑完：宁可界面卡一下，
                -- 也不要下载半途静默停在第 1 页。
                local oks = pcall(function()
                    UIManager:scheduleIn(0.05, stepOnce)
                end)
                if not oks then stepOnce() end
                return
            end
            stop(st, info)
        end)
    end
    stepOnce()
    -- 异步形态：对话框在说明节拍还没跑完，结果交给 on_done
    if state.finished then
        return out.ok and true or false, out.ok and out.man or out.err
    end
end

-- ---------- 缓存管理（下载内容 / Cookie） ----------

--- 存储剩余空间。真机有 util.diskUsage（返回 {total,used,free}），
--- 测试环境没有 util 模块 → 整段跳过，不影响界面其余部分。
local function freeSpaceText(dir)
    local ok, util = pcall(require, "util")
    if not (ok and util and util.diskUsage) then return nil end
    local okay, u = pcall(util.diskUsage, dir)
    if not okay or type(u) ~= "table" or not u.free then return nil end
    return fmtSize(u.free)
end

--- 已下载章节的操作菜单：点章节先给「读」，删除要再点一步。
--- 触屏上一划就删掉一话离线内容太容易误伤（重下要走网络 + 源登录态）。
function Browser:_showCachedChapterMenu(m, cache_menu)
    local ConfirmBox = require("ui/widget/confirmbox")
    local dl = self:getDownloader()
    local menu = self:_navMenu{
        title = _("已下载章节"),
        subtitle = (m.comicTitle or m.key) .. " / " .. (m.chapterTitle or m.epId)
            .. "（" .. #m.pages .. _(" 页 · ") .. fmtSize(m.bytes or 0) .. "）",
        item_table = {
            { text = _("阅读（离线打开，不联网）"), read = true },
            { text = _("删除本章"), delChapter = true },
        },
        onMenuSelect = function(menu_self, item)
            self:_guard(_("已下载章节"), function()
                if item.read then
                    -- 盖栈：阅读器压在本层之上，关闭后回到本章操作菜单
                    self:showReader(m.key, m.comicId, m.epId,
                        m.comicTitle, m.chapterTitle)
                elseif item.delChapter then
                    UIManager:show(ConfirmBox:new{
                        text = _("删除本章的离线文件？"),
                        ok_text = _("删除"),
                        ok_callback = function()
                            self:_guard(_("删除章节"), function()
                                dl:remove(m.key, m.comicId, m.epId)
                                UIManager:close(menu_self)
                                UIManager:close(cache_menu)
                                self:showCacheManager()
                            end)
                        end,
                    })
                end
            end)
        end,
    }
    UIManager:show(menu)
end

function Browser:showCacheManager()
    local ConfirmBox = require("ui/widget/confirmbox")
    local dl = self:getDownloader()
    local rows = dl:list()          -- 只有 manifest 完整、页 file 齐的才算
    local item_table = {}
    local head = (_("已下载 %d 话 · %s")):format(#rows, fmtSize(dl:usage()))
    local free = freeSpaceText(dl.basedir)
    if free then head = head .. "（" .. _("剩余 ") .. free .. "）" end
    table.insert(item_table, { text = "◆ " .. head, info_only = true })
    for _, m in ipairs(rows) do
        table.insert(item_table, {
            text = (m.comicTitle or m.key) .. " / " .. (m.chapterTitle or m.epId),
            mandatory = (("%d 页 · %s"):format(#m.pages, fmtSize(m.bytes))),
            cachedChapter = m,
        })
    end
    if #rows > 0 then
        table.insert(item_table, { text = _("清空全部下载"), clearAll = true })
    end
    if self.cookies then
        table.insert(item_table, { text = _("清空 Cookie（需重新登录各源）"),
            clearCookies = true })
    end
    table.insert(item_table, { text = _("说明：点已下载章节可离线阅读或删除"),
        info_only = true })

    local menu
    menu = self:_navMenu{
        title = _("下载与缓存"),
        item_table = item_table,
        onMenuSelect = function(menu_self, item)
            self:_guard(_("缓存管理"), function()
                if item.cachedChapter then
                    self:_showCachedChapterMenu(item.cachedChapter, menu_self)
                elseif item.clearAll then
                    UIManager:show(ConfirmBox:new{
                        text = _("清空全部已下载章节？（收藏与历史不动）"),
                        ok_text = _("清空"),
                        ok_callback = function()
                            self:_guard(_("清空下载"), function()
                                dl:clearAll()
                                UIManager:close(menu_self)
                                self:showCacheManager()
                            end)
                        end,
                    })
                elseif item.clearCookies then
                    UIManager:show(ConfirmBox:new{
                        text = _("清空 Cookie？各源需要重新登录。"),
                        ok_text = _("清空"),
                        ok_callback = function()
                            self:_guard(_("清空 Cookie"), function()
                                self.cookies:purge()
                                self:progressMessage(_("已清空 Cookie"))
                            end)
                        end,
                    })
                end
            end)
        end,
    }
    UIManager:show(menu)
end

-- ---------- 层级 6：阅读器（T18：opdspse 范式） ----------

--- 导航条是盖在阅读器之上的顶层窗口，而 UIManager:sendEvent（真机
--- v2026.07.1 uimanager.lua:884）只把「未被顶层窗口消费」的事件继续发给
--- is_always_active 的窗口——普通向下传播不存在。所以按钮区之外的点击会被
--- 这条带子整个吞掉，阅读器翻页失效，必须显式转交。
--- 只需转交 onGesture 一个：触屏输入在真机上统一以 Event:new("Gesture", ges)
--- 投递（device/input.lua:1092 等 6 处），ImageViewer 命中后再自己转成
--- onTap/onSwipe/onPan…（imageviewer.lua:112 的 ges_events，判定范围是整屏）。
--- Show/CloseWidget 等生命周期事件由 UIManager 直接投递，转交会重复渲染。
local pass_through_ges = { onGesture = true }

function Browser:showReader(key, comicId, epId, title, chapterTitle)
    local dl = self:getDownloader()
    -- 已下载 → 完全离线打开：一个网络请求都不发（无网/飞行模式也能读，
    -- 而且省掉 onImageLoad + loadEp 两次源方法调用，秒开）。
    local man = dl:manifestOf(key, comicId, epId)
    local images, base
    if man then
        images = Downloader.localImages(man)
    else
        self:progressMessage(_("章节加载中…"))
        local imgs, b, err = self:_loadEpImages(key, comicId, epId)
        if not imgs then
            self.infoMessage(err or _("章节加载失败"))
            return
        end
        images, base = imgs, b
    end
    if self.library then
        -- 章节确实取到了才记历史：失败也记会让「阅读历史」变成陷阱入口。
        self.library:recordRead({ key = key, comicId = comicId, title = title,
            epId = epId, epTitle = chapterTitle })
    end
    local RenderImage = require("ui/renderimage")
    local BB = require("ffi/blitbuffer")

    -- 【ANR · 2026-09-24 真机实证】点一次章节，回调里连着做 loadEp（源方法
    -- ~1s）+ 首页下载 + 首页解码。首页落在经代理不通的 CDN（baozicdn：代理
    -- 回完 CONNECT 就不发任何 TLS 字节）时，单张图要 20s（2 次重试 × 10s
    -- 握手超时）。KOReader 是单线程事件循环，这段时间主循环冻结，安卓
    -- InputDispatcher 5s 就弹「无响应：等待/关闭」。所以：
    --   · 单张图 1 次尝试 + 握手 3s / 整次 6s 封顶（健康链路：暖隧道 0.3s、
    --     冷隧道 1.2-2.1s；真机 baozicdn 改走直连后冷握手实测 2.5s，2s 会误杀），
    --     失败改由预取节拍补重试（IMG_TRIES 次）；
    --   · 打开章节的**首屏不在点击回调里联网**，先占位页，见 servePage。
    local IMG_OPTS = { attempts = 1, timeout_block = 3, timeout_total = 6 }
    local IMG_TRIES = 2

    local function fetchPage(item)
        -- 离线页 {local_file=}；在线页为 string url（Venera 契约）或
        -- {url=..., headers=...}
        if type(item) == "table" and item.local_file then
            return dl.fs.read(item.local_file)
        end
        local url, headers = item, nil
        if type(item) == "table" then
            url = item.url
            headers = item.headers
        end
        return self:fetchImageBytes(url, base, headers, IMG_OPTS)
    end

    -- 【R6 真机】ImageViewer 每次换页取 _images_list[cur]；拿到 nil 时
    -- ImageWidget:_render() 直接 error("cannot render image")，一张坏图
    -- 会终止整个 KOReader（crash.log 实证）。失败页给空白页而不是 nil。
    -- 占位 BB 现在可以复用同一个对象：页级 image_disposable=false 之后
    -- viewer 不再 free 我们给它的任何 BB（见 page_table 注释）。
    local placeholder_bb = nil
    local function placeholderPage()
        if placeholder_bb then return placeholder_bb end
        local ok, bb = pcall(function()
            local w, hgt = 600, 800
            local okd, Device = pcall(require, "device")
            if okd and Device and Device.screen then
                w = Device.screen:getWidth()
                hgt = Device.screen:getHeight()
            end
            local b = BB.new(w, hgt, BB.TYPE_BB8)
            b:fill(BB.COLOR_GRAY_E)
            return b
        end)
        if ok then placeholder_bb = bb end
        return bb
    end

    -- 【BB 所有权 · 2026-09-23 崩溃排查】两个同名不同义的 disposable 必须分开看：
    --   · 列表级 = ImageViewer:new{image_disposable=} → 存成 _images_list_disposable，
    --     决定 onCloseWidget 是否回调 page_table:free()。**保持 true**（回收缓存/预取）。
    --   · 页级 = page_table.image_disposable → 覆盖同名入参，决定 viewer 换页/关闭时
    --     是否 self.image:free()。**必须 false**：
    --     switchToImageNum 的顺序是"先 free 旧 BB(imageviewer.lua:478) → 再 update()
    --     → _clean_image_wg() 才销毁仍持有该 BB 的 ImageWidget(:324←:491)"，
    --     中间存在一个"BB 已 free、widget 仍引用"的窗口；而我们同一页会返回
    --     **同一个**缓存 BB（见 servePage），true 时回翻就会把已 C.free 数据缓冲的
    --     BB 再交出去 → 悬垂读（BB:free 本身幂等，问题不在二次 free 而在 free 后仍被引用）。
    -- 结论：BB 归我们所有，逐出/关闭时只丢引用，由 blitbuffer 的 ffi.gc 终值器回收。
    local page_table = { image_disposable = false }

    -- 【性能 + 内存】图片**字节**缓存。ImageViewer 每次换页都会重新取
    -- _images_list[pn]（imageviewer.lua:482 起），往回翻一页就把那张图重新
    -- 下载一遍；单图实测冷路径 1.2-2.1s，其中 TLS 握手占 0.8-0.95s。
    local cache = {}              -- pn → { data = 字节串, hdrs = 响应头, bb = 解码 BB }
    local cache_order = {}        -- 插入序，按字节预算逐出（页序单调 → 最前先弃）
    local cache_bytes = 0
    local CACHE_BUDGET = self.page_cache_bytes or (24 * 1024 * 1024)
    -- 解码后的 BB 单独计预算：一页 640x500 RGB32 ≈ 1.28MB，回翻不再重解码。
    local bb_order, bb_bytes = {}, 0
    local BB_BUDGET = self.page_bb_bytes or (12 * 1024 * 1024)
    local closed = false

    -- ---------- 章内导航（上一章 / 目录 / 下一章） ----------
    -- ImageViewer 的 onTap/onSwipe/onMultiSwipe 全部 `return true`（真机装的
    -- v2026.07.1 imageviewer.lua 实证），手势根本不会向下传，标题栏也没有可挂
    -- 按钮的位置。所以照 ConfigDialog 的做法在它上面叠一条
    -- BottomContainer + ButtonTable：按钮各自的 GestureRange 命中才消费事件，
    -- 其余位置的 onGesture 返回 nil → 事件继续向下 → 阅读器照常点击翻页。
    local viewer, nav_bar
    local function closeNavBar()
        local bar = nav_bar
        nav_bar = nil
        self._reader_nav = nil
        if bar then UIManager:close(bar) end
    end
    local function closeReader()
        local v = viewer
        viewer = nil
        if v then UIManager:close(v) end
    end

    --- 章节表：命中详情的缓存 → 源调用 → 离线兜底（本书已下载的话）。
    -- 第二返回值 true 表示拿到的是「离线子集」，第一档提示语要跟着变。
    local function chapterRows()
        local rows, err = self:_chapterList(key, comicId)
        if rows and #rows > 0 then
            return rows, rows.__offline_subset or false, nil
        end
        local out = {}
        for _, m in ipairs(dl:list()) do
            if m.key == key and tostring(m.comicId) == tostring(comicId) then
                out[#out + 1] = {
                    epId = m.epId, title = m.chapterTitle or tostring(m.epId),
                }
            end
        end
        table.sort(out, function(a, b) return chapterCmp(a.epId, b.epId) end)
        if #out > 0 then
            -- 兜底表也存进缓存：源不通时每次按导航都会重跑一次阻塞调用
            -- （真机一按白屏几秒），而离线子集本来就是当下能拿到的全部。
            -- 进详情 / 换源（invalidateSource）会用完整表覆盖或清掉它。
            out.__offline_subset = true
            return self:_cacheChapters(key, comicId, out), true, nil
        end
        return nil, false, err
    end

    local function chapterIndex(rows)
        for i, r in ipairs(rows) do
            if tostring(r.epId) == tostring(epId) then return i end
        end
    end

    --- 换章 = 关掉这一章的阅读器与导航条，再用同一入口开下一章。
    -- 复用入口而不是原地换 images 表：页缓存/预取队列/BB 所有权都跟
    -- showReader 的闭包绑在一起，原地换等于把这套生命周期抄第二遍。
    local function gotoChapter(target)
        closeNavBar()
        closeReader()
        self:showReader(key, comicId, target.epId, title, target.title)
    end

    local function stepChapter(delta)
        local rows, partial, err = chapterRows()
        if not rows then
            self.infoMessage(err or _("章节列表不可用"))
            return
        end
        local idx = chapterIndex(rows)
        if not idx then
            self.infoMessage(_("当前章节不在章节表里，请用【目录】选择"))
            return
        end
        local target = rows[idx + delta]
        if not target then
            if delta > 0 then
                self:progressMessage(_("已是最后一章"))
            else
                self:progressMessage(partial and _("离线列表中已是第一章")
                    or _("已是第一章"))
            end
            return
        end
        gotoChapter(target)
    end

    local function showToc()
        local rows, partial, err = chapterRows()
        if not rows then
            self.infoMessage(err or _("章节列表不可用"))
            return
        end
        local have = {}
        for _, m in ipairs(dl:list()) do
            if m.key == key and tostring(m.comicId) == tostring(comicId) then
                have[tostring(m.epId)] = true
            end
        end
        local item_table = {}
        local idx
        for i, r in ipairs(rows) do
            if tostring(r.epId) == tostring(epId) then idx = i end
            table.insert(item_table, {
                text = (have[tostring(r.epId)] and "◆ " or "○ ") .. r.title,
                mandatory = tostring(r.epId),
                epId = r.epId,
                chTitle = r.title,
            })
        end
        local menu
        menu = self:_navMenu{
            title = _("目录"),
            subtitle = tostring(title or "") .. (partial
                and _("（离线：只显示已下载章节）") or ""),
            item_table = item_table,
            onMenuSelect = function(menu_self, item)
                self:_guard(_("目录"), function()
                    if item.epId then
                        -- 导航条不用先关：目录是后 show 的，压在导航条之上，
                        -- 关掉后导航条自然又露出来（无需 show/close 往返）
                        UIManager:close(menu_self)
                        gotoChapter({ epId = item.epId, title = item.chTitle })
                    end
                end)
            end,
        }
        UIManager:show(menu)
        -- 定位到当前章所在页：不跳的话千话书永远开在第一页
        if idx then menu:switchItemTable(nil, nil, idx) end
    end

    local function showNavBar()
        local Device = require("device")
        local BottomContainer = require("ui/widget/container/bottomcontainer")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local ButtonTable = require("ui/widget/buttontable")
        local BBc = require("ffi/blitbuffer")
        local scr = Device.screen
        nav_bar = BottomContainer:new{
            dimen = scr:getSize(),
            FrameContainer:new{
                background = BBc.COLOR_WHITE,
                bordersize = 0,
                margin = 0,
                padding = 0,
                ButtonTable:new{
                    width = scr:getWidth(),
                    buttons = { {
                        { text = _("上一章"),
                          callback = function() stepChapter(-1) end },
                        { text = _("目录"), callback = showToc },
                        { text = _("下一章"),
                          callback = function() stepChapter(1) end },
                    } },
                },
            },
        }
        -- 【真机踩到】盖在阅读器之上的顶层窗口会吞掉按钮区之外的全部点击，
        -- 阅读器点不动。这里把没被按钮吃掉的手势转交给阅读器（点左/右 1/3
        -- 翻页、拖动、缩放全部照常）。理由见文件头 pass_through_ges 注释。
        local base_handle = nav_bar.handleEvent
        function nav_bar:handleEvent(event)
            if base_handle(self, event) then return true end
            if viewer and pass_through_ges[event.handler] then
                return viewer:handleEvent(event)
            end
        end
        UIManager:show(nav_bar)
        self._reader_nav = { step = stepChapter, toc = showToc }
    end


    -- 【临时探针·排查完删除】章节阅读期真机三次同签名 SIGSEGV（libluajit 内
    -- lua_rawset 区段，进入章节 40-60s 后，无 Failed to run script 前导、无
    -- lmkd kill）→ 需要进程内存曲线区分「分配耗尽」与「FFI/终值器破坏」。
    -- 采样走 2s 自续节拍：一次复现不依赖翻页动作，静置也能出曲线。
    local diag_n, diag_pn = 0, nil
    local function diagSample(tag)
        diag_n = diag_n + 1
        local rss, hwm, peak = "?", "?", "?"
        local okf, f = pcall(io.open, "/proc/self/status", "r")
        if okf and f then
            local okc, t = pcall(function() return f:read("*a") end)
            f:close()
            if okc and t then
                rss = t:match("VmRSS:%s+(%d+)") or "?"
                hwm = t:match("VmHWM:%s+(%d+)") or "?"
                peak = t:match("VmPeak:%s+(%d+)") or "?"
            end
        end
        local okl, luckb = pcall(collectgarbage, "count")
        logger.warn("ezveneraDIAG", tag, " n=", diag_n, " pn=", tostring(diag_pn),
            " rss_kb=", rss, " hwm_kb=", hwm, " peak_kb=", peak,
            " lua_kb=", (okl and math.floor(luckb)) or "?",
            " cache_kb=", math.floor(cache_bytes / 1024), " nb=", #images)
    end
    local function diag(pn)
        diag_pn = pn
        diagSample("page")
    end
    local function diagTick()
        if closed then return end
        guardCall("探针", function() diagSample("tick") end)
        local ok = pcall(function()
            UIManager:scheduleIn(2, diagTick)
        end)
        if not ok then logger.warn("ezveneraDIAG: tick schedule failed") end
    end

    -- 连续失败计数：一张取不到的图如果在每次重绘时都去撞 4s 的超时，翻页
    -- 手感就全没了，而且够不着 5s 也会把 ANR _dialog 攒出来。取成功即清零
    -- （页字节被逐出后仍可重新取）。
    local tries = {}
    -- 【ANR + 流量】图床整个不通时（baozicdn 经代理实测每页要 2.2s 才失败），
    -- 预取会把整章 95 页 × 重试次数全撞一遍。连续 3 页失败即停手；用户翻到哪
    -- 页仍会有一次有界尝试，成功就恢复预取。
    local dead = 0
    local function loadInto(pn)
        local hit = cache[pn]
        if hit then return hit.data, hit.hdrs end
        local item = images[pn]
        if item == nil then return nil end
        if (tries[pn] or 0) >= IMG_TRIES then return nil end
        tries[pn] = (tries[pn] or 0) + 1
        local data, hdrs = fetchPage(item)
        if data then
            tries[pn] = nil
            dead = 0
        else
            dead = dead + 1
        end
        if data and not cache[pn] then
            cache[pn] = { data = data, hdrs = hdrs }
            cache_bytes = cache_bytes + #data
            table.insert(cache_order, pn)
            while cache_bytes > CACHE_BUDGET and #cache_order > 1 do
                local old = table.remove(cache_order, 1)
                local e = cache[old]
                if e then
                    if e.bb and old ~= pn then
                        -- 逐出字节 = 逐出解码 BB（否则预算形同虚设）；正在取的
                        -- 这一页不逐，否则刚返回的 BB 会失去引用被终值器回收。
                        bb_bytes = bb_bytes - (e.bb_bytes or 0)
                        e.bb = nil
                        for j = #bb_order, 1, -1 do
                            if bb_order[j] == old then
                                table.remove(bb_order, j)
                                break
                            end
                        end
                    end
                    cache[old] = nil
                    cache_bytes = cache_bytes - #e.data
                end
            end
        end
        return data, hdrs
    end

    -- 预取：读到第 N 页就把 N+1..N+AHEAD 排进队列，每个 tick 只取一张
    -- （一张暖隧道约 0.3s，长时间占住主循环会让翻页手感变差）。
    local PREFETCH_AHEAD = 3
    local prefetch_queue = {}
    local prefetch_running = false
    -- 首屏标记：打开章节的那一次绘制（ImageViewer 构造里同步取
    -- _images_list[1]）不联网，见 servePage。离线章节读的是本地文件，没有
    -- 网络可避，不必延迟（延迟反而多一次灰屏）。
    local first_paint = man == nil
    --- 补画当前显示的那一屏：只重建 ImageViewer 的 ImageWidget（update 内部
    --- _clean_image_wg → _new_image_wg），不动翻页/缩放状态。
    local function repaintIfVisible(pn)
        if closed or not viewer then return end
        if viewer._images_list_cur ~= pn then return end
        local ok, err = pcall(function()
            viewer.image = page_table[pn]
            viewer:update()
        end)
        if not ok then
            logger.warn("ezvenera: repaint p" .. tostring(pn) .. " failed:",
                tostring(err))
        end
    end
    local function schedulePrefetch()
        if closed or dead >= 3 or prefetch_running or #prefetch_queue == 0 then
            return
        end
        prefetch_running = true
        local ok = pcall(function()
            UIManager:scheduleIn(0.2, function()
                prefetch_running = false
                -- 回调由 UIManager 的分发循环直接调用：错误冒出去就是
                -- 见 guardCall 注释：错误冒到主循环即整应用闪退。
                guardCall("预取", function()
                    if closed then return end
                    local pn = table.remove(prefetch_queue, 1)
                    if pn and not cache[pn] then
                        if loadInto(pn) then
                            -- 这一页可能正是当前显示的那一屏（首屏就是走这条
                            -- 路补上来的），取到了就补画一次。
                            repaintIfVisible(pn)
                        elseif (tries[pn] or 0) < IMG_TRIES then
                            -- 失败改到下一个节拍重试：原本写在 fetchImageBytes
                            -- 里的第 2 次尝试不能再放在同一次回调里。
                            table.insert(prefetch_queue, pn)
                        end
                    end
                    schedulePrefetch()
                end)
            end)
        end)
        if not ok then prefetch_running = false end
    end
    --- 把 pn 插到队列最前面（去重）。首屏与取页失败后的补试都用它。
    local function enqueueNow(pn)
        if (tries[pn] or 0) >= IMG_TRIES then return end
        for _, q in ipairs(prefetch_queue) do
            if q == pn then return schedulePrefetch() end
        end
        table.insert(prefetch_queue, 1, pn)
        schedulePrefetch()
    end
    local function wantAhead(pn)
        for i = pn + 1, math.min(#images, pn + PREFETCH_AHEAD) do
            if not cache[i] then
                local dup = false
                for _, q in ipairs(prefetch_queue) do
                    if q == i then dup = true break end
                end
                if not dup then table.insert(prefetch_queue, i) end
            end
        end
        schedulePrefetch()
    end

    page_table.free = function()
        -- ImageViewer 以列表级 image_disposable=true 触发（onCloseWidget）。
        -- 只丢引用：BB 的数据缓冲由 blitbuffer 的 ffi.gc 终值器回收，
        -- 我们不在这里 :free() —— 关闭时序里 viewer/正在重绘的 widget 可能
        -- 仍持有该 BB 的引用。
        closed = true
        -- 导航条是叠在阅读器之上的独立窗口：阅读器没了它必须跟着没，否则
        -- 三条按钮会留在上一层界面之上、点了没反应。
        closeNavBar()
        cache = {}
        cache_order = {}
        cache_bytes = 0
        bb_order = {}
        bb_bytes = 0
        placeholder_bb = nil
        for i = #prefetch_queue, 1, -1 do prefetch_queue[i] = nil end
        diagSample("close")
    end

    local function servePage(pn)
        diag(pn)
        if images[pn] == nil then return placeholderPage() end
        wantAhead(pn)
        -- 【ANR】只有打开章节后的第一次绘制走延迟：那一次回调里已经花掉
        -- loadEp（源方法）的时间，再在里面下载+解码一张最坏要 4s 的图就会
        -- 踩到安卓的 5s 输入超时。之后翻页仍可同步取（暖隧道 0.3s）。
        local defer = first_paint
        first_paint = false
        if defer and not cache[pn] then
            enqueueNow(pn)
            return placeholderPage()
        end
        local data, hdrs = loadInto(pn)
        if not data then
            -- 失败不再原地重试（见 IMG_OPTS）：交给节拍补试，够 IMG_TRIES 次。
            enqueueNow(pn)
            return placeholderPage()
        end
        local entry = cache[pn]
        if entry and entry.bb then return entry.bb end
        local okr, bb = pcall(function()
            return RenderImage:renderImageData(data, #data, false)
        end)
        if not okr or not bb then
            -- 【R7 真机】下载成功但解不出图：多半是反爬/登录页的 HTML。
            -- 与"取不到图"是两种病因，必须分开留痕（响应头 + 首字节）。
            local sniff = (data:sub(1, 60):gsub("[%c]", " "))
            logger.warn("ezvenera: image decode failed:",
                tostring(hdrs and (hdrs["content-type"] or hdrs["Content-Type"])),
                #data, sniff)
            return placeholderPage()
        end
        if entry then
            -- 只有进了缓存表才持有：否则本次 BB 由 viewer/GC 负责。
            entry.bb = bb
            entry.bb_bytes = tonumber(bb.stride) * tonumber(bb.h) or 0
            bb_bytes = bb_bytes + entry.bb_bytes
            table.insert(bb_order, pn)
            while bb_bytes > BB_BUDGET and #bb_order > 1 do
                local old = table.remove(bb_order, 1)
                -- pn 是正在显示的一页，绝不逐出
                if old ~= pn and cache[old] and cache[old].bb then
                    bb_bytes = bb_bytes - (cache[old].bb_bytes or 0)
                    cache[old].bb = nil
                end
            end
        end
        return bb
    end

    -- __index 由 ImageViewer 的翻页/绘制路径直接调用，错误冒到主循环就会撞上
    -- 见 guardCall 注释（错误冒到主循环 = 闪退，R9 真机实证），所以这里
    -- 收住错误并退回占位页：一页坏图不该终止整个应用。
    setmetatable(page_table, { __index = function(_, pn)
        if type(pn) ~= "number" then return nil end
        local okp, page = xpcall(servePage,
            function(msg) return tostring(msg) end, pn)
        if not okp then
            logger.warn("ezvenera: page " .. tostring(pn) .. " 取页失败:", page)
        end
        return page or placeholderPage()
    end })

    local ImageViewer = require("ui/widget/imageviewer")
    -- 兜底：构造/show 阶段会同步取首页（下载+解码）。这里的 Lua 错误若
    -- 冒泡到 KOReader 主循环，整个应用会被 CrashReportActivity 终止
    -- （R6 实证），故收口成一条提示。
    local okshow, showerr = pcall(function()
        viewer = ImageViewer:new{
            image = page_table,
            fullscreen = true,
            -- 【真机"只有关闭无返回"】标题栏给出退出入口（X 关阅读器 →
            -- 回到仍在其下的章节菜单），并显示章节名。
            with_title_bar = true,
            title_text = tostring(chapterTitle or title or _("章节")),
            -- 这是**列表级**的 disposable（imageviewer.lua:153-154 先把它
            -- 存成 _images_list_disposable，再用 page_table.image_disposable
            -- 覆盖同名字段）。true 时 onCloseWidget 会调 page_table:free()，
            -- 阅读器持有的缓存与预取任务由此回收。
            image_disposable = true,
            images_list_nb = #images,
        }
        UIManager:show(viewer)
    end)
    if not okshow then
        viewer = nil
        logger.warn("ezvenera: reader open failed:", tostring(showerr))
        self.infoMessage(_("无法打开章节：") .. tostring(showerr))
    else
        -- 先让阅读器把首页画出来，再叠导航条（顺序反了会先画一条悬空白条）
        local oknav, naverr = pcall(showNavBar)
        if not oknav then
            nav_bar = nil
            logger.warn("ezvenera: nav bar open failed:", tostring(naverr))
        end
        diagTick()
    end
end

-- ---------- 收藏夹 / 阅读历史（本地数据，不联网） ----------
-- 真机反馈：源 → 分类 → 结果 → 详情 → 章节 五层，回看一本书要点五次并等两次
-- 网络。这两个入口直接从本地存储跳到详情/上次的章节。

function Browser:showFavorites()
    if not self.library then
        self.infoMessage(_("收藏不可用：未接存储。"))
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    local favs = self.library:listFavorites()
    local item_table = {}
    for _, f in ipairs(favs) do
        table.insert(item_table, {
            text = (f.title ~= "" and f.title) or tostring(f.comicId),
            mandatory = f.key,
            fav = f,
        })
    end
    if #favs == 0 then
        table.insert(item_table, { text = _("（还没有收藏）"), info_only = true })
    else
        table.insert(item_table, { text = _("清空收藏夹"), clear_fav = true })
    end
    local menu
    menu = self:_navMenu{
        title = _("收藏夹") .. "（" .. tostring(#favs) .. "）",
        item_table = item_table,
        onMenuSelect = function(menu_self, item)
            self:_guard(_("收藏夹"), function()
                if item.fav then
                    -- 盖栈：详情压在本层之上，返回箭头回到收藏夹
                    self:showDetail(item.fav.key, {
                        id = item.fav.comicId, title = item.fav.title,
                    })
                elseif item.clear_fav then
                    UIManager:show(ConfirmBox:new{
                        text = _("清空整个收藏夹？"),
                        ok_text = _("清空"),
                        ok_callback = function()
                            self:_guard(_("清空收藏夹"), function()
                                self.library:clearFavorites()
                                UIManager:close(menu_self)
                            end)
                        end,
                    })
                end
            end)
        end,
    }
    UIManager:show(menu)
end

function Browser:showHistory()
    if not self.library then
        self.infoMessage(_("历史不可用：未接存储。"))
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    local hist = self.library:listHistory()
    local item_table = {}
    for _, h in ipairs(hist) do
        local label = (h.title ~= "" and h.title) or tostring(h.comicId)
        if h.epTitle or h.epId then
            label = label .. " · " .. tostring(h.epTitle or h.epId)
        end
        table.insert(item_table, {
            text = label, mandatory = h.key, hist = h,
        })
    end
    if #hist == 0 then
        table.insert(item_table, { text = _("还没有阅读记录"), info_only = true })
    else
        table.insert(item_table, { text = _("清空阅读历史"), clear_hist = true })
    end
    local menu
    menu = self:_navMenu{
        title = _("阅读历史") .. "（" .. tostring(#hist) .. "）",
        item_table = item_table,
        onMenuSelect = function(menu_self, item)
            self:_guard(_("阅读历史"), function()
                if item.hist then
                    -- 盖栈：续读/详情压在本层之上，返回箭头回到历史列表
                    local h = item.hist
                    if h.epId then
                        -- 直接续读上次那一章（详情/章节列表仍可从阅读器返回）
                        self:showReader(h.key, h.comicId, h.epId, h.title,
                            h.epTitle)
                    else
                        self:showDetail(h.key, { id = h.comicId,
                            title = h.title })
                    end
                elseif item.clear_hist then
                    UIManager:show(ConfirmBox:new{
                        text = _("清空阅读历史？"),
                        ok_text = _("清空"),
                        ok_callback = function()
                            self:_guard(_("清空阅读历史"), function()
                                self.library:clearHistory()
                                UIManager:close(menu_self)
                            end)
                        end,
                    })
                end
            end)
        end,
    }
    UIManager:show(menu)
end

-- ---------- 源参数配置 / 账号（学习上游 EZVenera sources_page.dart） ----------
--
-- 上游把源参数存在**源自己的数据槽**里：data['settings'][key]
-- （plugin_js_engine.dart 的 load_setting），所以插件界面必须写同一个文件，
-- JS 侧 loadSetting 才读得到 —— 读写收口在 runtime/sourcedata.lua。
-- 登录态同理：登录成功后由宿主写 data['_ez_logged']=true（markLoggedIn）。
-- 多数源登录只 saveData('token')，自己不动标记，而源里的 `this.isLogged`
-- 又只看宿主给的答案（models.dart `bool get isLogged`）——少了这一步，
-- picacg 这类源登录完仍然报 "Not logged in"。

--- 「继续上次阅读」：历史首条就是上次看的那一话（upsert 置顶）。
--- 这是高频入口（主菜单首项 + 可绑手势/快捷键），省掉 源→分类→结果→详情→章节
--- 五层点击；已下载的章节会直接离线打开。
function Browser:resumeLast()
    if not self.library then
        self.infoMessage(_("续读不可用：未接存储。"))
        return
    end
    local h = self.library:listHistory()[1]
    if not h then
        self.infoMessage(_("还没有阅读记录：先去「浏览漫画源」看一话。"))
        return
    end
    self:_guard(_("继续上次阅读"), function()
        if h.epId then
            self:showReader(h.key, h.comicId, h.epId, h.title, h.epTitle)
        else
            self:showDetail(h.key, { id = h.comicId, title = h.title })
        end
    end)
end

function Browser:_srcdata()
    if not self._sd then
        self._sd = self.sourcedata or SourceData.new{}
    end
    return self._sd
end

--- 写单个参数。落盘失败必须说清楚：否则界面回显的还是旧值，用户以为改了。
function Browser:_writeSetting(jsKey, st_key, value)
    if self:_srcdata():setSetting(jsKey, st_key, value) then return true end
    self.infoMessage(_("保存失败：数据目录不可写，参数未生效。"))
    return false
end

--- 参数值 → 一行显示文本（switch 显示成中文，nil 显示空）
local function shownValue(v)
    if v == true then return _("开") end
    if v == false then return _("关") end
    if v == nil then return "" end
    return tostring(v)
end

--- 源声明 + 已存参数 → 菜单行。纯函数，单测覆盖。
--- 取值规则照上游：已存值 ?? 源声明的 default（sources_page.dart:590）
function Browser:_settingRows(info, stored)
    local rows = {}
    for _, st in ipairs((info and info.settings) or {}) do
        local cur = stored[st.key]
        if cur == nil then cur = st.def end
        table.insert(rows, {
            text = st.title,
            mandatory = shownValue(cur),
            setting = st,
            value = cur,
        })
    end
    return rows
end

--- 单行输入框（范式同 proxyconf.lua 的代理地址编辑，真机已验证）。
--- onOk 收到的是**原始**输入；去空白由调用方决定（上游：账号去空白、
--- 口令原样，sources_page.dart:823）。
--- opts = { title, initial, hint, description, password, confirm_text }
function Browser:_inputBox(opts, onOk)
    local okDlg, InputDialog = pcall(require, "ui/widget/inputdialog")
    if not okDlg then
        self.infoMessage(_("输入框仅在 KOReader 内可用。"))
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = opts.title,
        input = opts.initial or "",
        input_hint = opts.hint,
        description = opts.description,
        text_type = opts.password and "password" or nil,
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = opts.confirm_text or _("保存"),
                    is_enter_default = true,
                    callback = function()
                        -- 这里是 KOReader widget 直接调用的入口：错误漏出去
                        -- 就走 R9 崩溃链（错误冒到 KOReader 主循环 → 整应用闪退）
                        self:_guard(opts.title or _("输入"), function()
                            onOk(dialog:getInputText() or "", dialog)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 下拉型参数：列出声明的选项
function Browser:_pickOption(jsKey, st, cur, done)
    local opts = st.options or {}
    if #opts == 0 then
        self.infoMessage(_("该参数没有可选项（源声明的 options 为空）。"))
        return
    end
    local rows = {}
    for _, o in ipairs(opts) do
        table.insert(rows, {
            text = o.text,
            mandatory = o.value,
            value = o.value,
            marked = tostring(o.value) == tostring(cur),
        })
    end
    local menu
    menu = self:_navMenu{
        title = st.title,
        item_table = rows,
        onMenuSelect = function(menu_self, item)
            UIManager:close(menu_self)
            self:_guard(_("参数配置"), function()
                self:_writeSetting(jsKey, st.key, item.value)
                done()
            end)
        end,
    }
    UIManager:show(menu)
end

--- 按类型分派编辑器。写完调 done()（回到参数列表，值即时刷新）
function Browser:_editSetting(jsKey, st, cur, done)
    if st.type == "switch" then
        self:_writeSetting(jsKey, st.key, not (cur == true))
        done()
        return
    end
    if st.type == "select" then
        self:_pickOption(jsKey, st, cur, done)
        return
    end
    self:_inputBox({
        title = st.title,
        initial = shownValue(cur),
        description = st.validator and st.validator ~= ""
            and (_("合法值需匹配：") .. tostring(st.validator)) or nil,
    }, function(v, dialog)
        v = (v:gsub("^%s+", ""):gsub("%s+$", ""))
        if st.validator and st.validator ~= "" then
            local okv, verr = self.engine:testSettingValue(st.validator, v)
            if okv == false then
                -- 校验不过就留着对话框让用户改（上游同样行为：显示 errorText）
                self.infoMessage(_("值不符合该源的要求：") .. tostring(verr))
                return
            end
        end
        UIManager:close(dialog)
        self:_writeSetting(jsKey, st.key, v)
        done()
    end)
end

--- 已安装源的参数配置界面
function Browser:showSourceSettings(key)
    local jsKey, lerr = self:_ensureSourceLoaded(key)
    if not jsKey then
        self.infoMessage(_("参数配置需要 JS 引擎：") .. "\n" .. tostring(lerr))
        return
    end
    local info, serr = self.engine:sourceInfo(jsKey)
    if not info then
        self.infoMessage(_("读取源参数声明失败：") .. tostring(serr))
        return
    end
    local rows = self:_settingRows(info, self:_srcdata():allSettings(jsKey))
    if #rows == 0 then
        self.infoMessage(_("该源没有声明可配置参数。"))
        return
    end
    table.insert(rows, { text = _("恢复默认（清除已保存的参数）"),
        reset_row = true })
    local menu
    menu = self:_navMenu{
        title = _("源参数配置"),
        item_table = rows,
        onMenuSelect = function(menu_self, item)
            self:_guard(_("参数配置"), function()
                if item.reset_row then
                    if self:_srcdata():clearSettings(jsKey) then
                        self.infoMessage(_("已恢复源声明的默认参数。"))
                    else
                        self.infoMessage(_("清除失败：数据目录不可写。"))
                    end
                    return
                end
                UIManager:close(menu_self)
                self:_editSetting(jsKey, item.setting, item.value, function()
                    self:showSourceSettings(key)
                end)
            end)
        end,
    }
    UIManager:show(menu)
end

--- 账号密码登录。两步输入：账号 → 密码（InputDialog 的 text_type=
--- "password" 有遮罩 + 显示切换）。口令**不落盘**：KOReader 安卓数据目录在
--- /sdcard 共享存储上，其它应用可读，写进去等于明文泄露。
function Browser:showLoginDialog(key)
    local jsKey, lerr = self:_ensureSourceLoaded(key)
    if not jsKey then
        self.infoMessage(_("登录需要 JS 引擎：") .. "\n" .. tostring(lerr))
        return
    end
    self:_inputBox({
        title = _("账号 / 邮箱"),
        confirm_text = _("下一步"),
    }, function(raw_user, dlg1)
        -- 上游只 trim 账号，口令原样传（sources_page.dart:823）
        local user = (raw_user:gsub("^%s+", ""):gsub("%s+$", ""))
        if user == "" then
            self.infoMessage(_("账号不能为空。"))
            return
        end
        UIManager:close(dlg1)
        self:_inputBox({
            title = _("密码") .. " (" .. user .. ")",
            password = true,
            confirm_text = _("登录"),
        }, function(pwd, dlg2)
            UIManager:close(dlg2)
            self:_doLogin(key, jsKey, user, pwd)
        end)
    end)
end

function Browser:_doLogin(key, jsKey, user, pwd)
    -- 引擎持的就是桥在用的 json（KOReader 内建）；再 require 一次反而在
    -- 测试环境里拿不到模块。
    local J = self.engine and self.engine.json
    if not J or not J.encode then
        self.infoMessage(_("json 模块不可用，无法提交登录参数。"))
        return
    end
    self:progressMessage(_("登录中…"))
    -- 注意不能写成 `local _, err`：`_` 是本模块的 gettext 别名，
    -- 遮蔽后下面的 _("登录失败：") 直接炸（真机表现：登录永远没反馈）
    local _val, err = self:_awaitSource(key, "account.login",
        "[" .. J.encode(user) .. "," .. J.encode(pwd) .. "]")
    if err then
        self.infoMessage(_("登录失败：") .. tostring(err))
        return
    end
    self:_srcdata():markLoggedIn(jsKey)
    self.infoMessage(_("登录成功。返回源主页重试即可。"))
end

--- 注销：照上游顺序（markLoggedOut → account.logout → 落盘）。
--- 我们的落盘是每次操作即时写，不需要额外 save。
function Browser:_confirmLogout(key, jsKey)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("注销该源的登录？\n源自身的凭据（token 等）也会清除。"),
        ok_text = _("注销"),
        ok_callback = function()
            self:_guard(_("注销登录"), function()
                self:_srcdata():markLoggedOut(jsKey)
                local _val, err = self:_awaitSource(key, "account.logout",
                    "[]")
                if err then
                    logger.warn("ezvenera: account.logout failed:", err)
                end
                self.infoMessage(_("已注销 ") .. tostring(jsKey))
            end)
        end,
    })
end

--- 删除源的实际动作：清单+js 文件 → 作废内存注册 → 连本地数据文件一起清。
--- 数据文件里是 token/参数，源都没了留着只有两个害处（占空间、下次装同名源
--- 时读到旧凭据）。engine 不可用也要能删，故不依赖 jsKey。
--- 返回 (ok, err)
function Browser:_removeSource(key)
    if not self.sources then return false, _("未接源存储") end
    local jsKey = self._registered and self._registered[key]
    local ok, err = self.sources:remove(key)
    if not ok then
        local e = tostring(err or "")
        if e:find("not installed", 1, true) then
            e = _("清单里没有这个源（可能已被删除）")
        end
        return false, e
    end
    self:invalidateSource(key)
    -- 数据文件删不掉不影响「源已删除」这个结论：静默记日志即可
    local okp, perr = pcall(function()
        self:_srcdata():purge(key)
        if jsKey and jsKey ~= key then self:_srcdata():purge(jsKey) end
    end)
    if not okp then logger.warn("ezvenera: purge source data failed:", key, perr) end
    return true
end

--- 删除源（源文件 + 本地数据）。engine 不可用也要能删，故不依赖 jsKey。
function Browser:_confirmRemoveSource(key)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("删除源 ") .. tostring(key) .. _("？\n源文件与数据将移除。"),
        ok_text = _("删除"),
        ok_callback = function()
            self:_guard(_("删除源"), function()
                local ok2, err = self:_removeSource(key)
                if ok2 then
                    self.infoMessage(_("已删除 ") .. tostring(key))
                else
                    self.infoMessage(_("删除失败：") .. tostring(err))
                end
            end)
        end,
    })
end

--- 批量删除已安装源（多选）。ADR-005：一行一次点击，全部普通 callback。
--- 源行只切换 ◆/○ 标记；真正的删除要点「删除所选」并在 ConfirmBox 再确认
--- 一次（多选界面最怕手一滑少一个源）。整包导入后要清掉一批源时，
--- 逐个进单源菜单点删除不是办法（用户反馈：30 个源删到手酸还报错）。
function Browser:showSourceMultiDelete()
    if not self.sources then
        self.infoMessage(_("源列表不可用：未接存储。"))
        return
    end
    local inst = self.sources:listInstalled()
    if #inst == 0 then
        self.infoMessage(_("尚未安装任何源。"))
        return
    end
    local marked, n_marked = {}, 0
    local menu
    local on_select                       -- 前向声明：redraw 构造菜单时引用

    local function count_marked()
        local n = 0
        for _, e in ipairs(inst) do
            if marked[e.key] then n = n + 1 end
        end
        return n
    end

    local function build_rows()
        local out = {}
        for _, e in ipairs(inst) do
            table.insert(out, {
                text = (marked[e.key] and "◆ " or "○ ")
                    .. tostring(e.name or e.key),
                mandatory = e.key, pick_key = e.key,
            })
        end
        table.insert(out, { text = _("说明：点一行切换选中（◆=将删除）"),
            info_only = true })
        table.insert(out, { text = _("全选"), all_row = true })
        table.insert(out, { text = _("清空选择"), none_row = true })
        table.insert(out, { text = _("删除所选") .. "（" .. n_marked .. "）",
            del_row = true })
        return out
    end

    local function redraw()
        local title = _("批量删除源") .. "（" .. n_marked .. "/"
            .. tostring(#inst) .. "）"
        local rows = build_rows()
        -- KOReader 的 Menu 支持原地换表；桩或老版本没有则关旧开新（同一套
        -- 行表与回调，行为一致）。
        local ok = menu and menu.switchItemTable
            and pcall(function() menu:switchItemTable(title, rows) end)
        if ok then return end
        if menu then UIManager:close(menu) end
        menu = self:_navMenu{
            title = title,
            item_table = rows,
            onMenuSelect = on_select,
        }
        UIManager:show(menu)
    end

    on_select = function(menu_self, item)
        self:_guard(_("批量删除源"), function()
            if item.info_only then return end
            if item.pick_key then
                local k = item.pick_key
                if marked[k] then marked[k] = nil else marked[k] = true end
                n_marked = count_marked()
                redraw()
            elseif item.all_row then
                for _, e in ipairs(inst) do marked[e.key] = true end
                n_marked = count_marked()
                redraw()
            elseif item.none_row then
                marked = {}
                n_marked = 0
                redraw()
            elseif item.del_row then
                local keys = {}
                for _, e in ipairs(inst) do
                    if marked[e.key] then table.insert(keys, e.key) end
                end
                if #keys == 0 then
                    self.infoMessage(_("还没有选中任何源：先点几行（○ 变 ◆）。"))
                    return
                end
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("删除选中的 ") .. tostring(#keys)
                        .. _(" 个源？\n源文件与本地数据（参数、登录态）一并移除，不可恢复。"),
                    ok_text = _("删除"),
                    ok_callback = function()
                        self:_guard(_("批量删除源"), function()
                            local gone, fails = 0, {}
                            for _, k in ipairs(keys) do
                                local ok2, err = self:_removeSource(k)
                                if ok2 then
                                    gone = gone + 1
                                    marked[k] = nil
                                else
                                    table.insert(fails, tostring(k) .. "："
                                        .. tostring(err))
                                end
                            end
                            inst = self.sources:listInstalled()
                            n_marked = count_marked()
                            local msg = _("已删除 ") .. tostring(gone)
                                .. _(" 个源")
                            if #fails > 0 then
                                msg = msg .. _("，失败 ") .. tostring(#fails)
                                    .. _(" 个：\n") .. table.concat(fails, "\n")
                            end
                            if #inst == 0 then
                                -- 全删光了：留一个空菜单在屏上没意义
                                UIManager:close(menu)
                                menu = nil
                                self.infoMessage(msg .. _("\n已安装源已清空。"))
                            else
                                redraw()
                                self.infoMessage(msg)
                            end
                        end)
                    end,
                })
            end
        end)
    end

    redraw()
end

--- 单个已安装源的操作菜单（参数配置 / 登录 / 清除数据 / 删除）。
--- 全部用普通菜单项 callback，不用 hold（ADR-005）。
function Browser:showSourceMenu(key, name, version)
    local jsKey, lerr = self:_ensureSourceLoaded(key)
    local info, serr, logged
    if jsKey then
        -- sourceInfo 是双返回值：这里只接第一个会把错误串丢进 info（真机
        -- 上「参数：-」永远查不到原因）。
        info, serr = self.engine:sourceInfo(jsKey)
        logged = self:_srcdata():isLogged(jsKey)
    end
    -- 源未声明 account 时 JSON 是 null。jshost 已把哨兵剥成 nil，这里再钉
    -- 一次类型：真机 logcat 的原始崩溃就是 `acc.login` 索引 null 哨兵
    -- （attempt to index local 'acc' (a function value)）——源菜单打不开，
    -- 菜单里唯一的「删除源」项自然也就点不到（用户报的「删除出错」）。
    local acc = type(info) == "table" and info.account
    if type(acc) ~= "table" then acc = nil end
    local nset = info and tostring(#(info.settings or {})) or "-"
    local rows = {
        {
            text = _("源信息"),
            mandatory = jsKey and (logged and _("已登录") or _("未登录")) or "",
            info_row = true,
        },
        { text = _("参数配置…"), mandatory = nset, settings_row = true },
    }
    if acc and acc.login then
        table.insert(rows, { text = _("账号登录…"), login_row = true })
    end
    if acc and acc.logout then
        table.insert(rows, { text = _("注销登录"), logout_row = true })
    end
    -- 上游账号能力有 loginWebsite / registerWebsite 两个地址；KOReader 没有
    -- 内置浏览器，但至少把地址显示出来（注册/找回口令要去手机浏览器做）。
    local site = acc and (type(acc.website) == "string" and acc.website
        or type(acc.register) == "string" and acc.register)
    if site then
        table.insert(rows, { text = _("注册/登录网址"), url = site,
            mandatory = _("查看") })
    end
    if jsKey then
        table.insert(rows, { text = _("清除本地数据（含登录态）"),
            clear_row = true })
    end
    table.insert(rows, { text = _("删除源…"), remove_row = true })
    local menu
    menu = self:_navMenu{
        title = self:_crumbTitle(key, (name or key)
            .. "  v" .. tostring(version or "?")),
        item_table = rows,
        onMenuSelect = function(menu_self, item)
            self:_guard(_("源管理"), function()
                -- 盖栈（§10 O2）：配置/登录/信息类分支不再先关本层——
                -- 子界面压在其上，返回箭头即回本菜单；仅数据变更分支
                -- （清除/删除）在弹出确认框前收起本层（旧有语义）。
                if item.info_row then
                    self.infoMessage(_("源：") .. tostring(name or key)
                        .. "\n" .. _("版本：") .. tostring(version or "?")
                        .. "\n" .. _("引擎内 key：") .. tostring(jsKey or "-")
                        .. "\n" .. _("登录状态：")
                        .. (jsKey and (logged and _("已登录") or _("未登录"))
                            or _("引擎不可用"))
                        .. "\n" .. _("可配置参数：") .. nset
                        .. (serr and ("\n" .. _("参数声明读取：")
                                .. tostring(serr)) or "")
                        .. (jsKey and "" or
                            _("\n\n引擎不可用：参数与登录需要引擎。")))
                elseif item.settings_row then
                    self:showSourceSettings(key)
                elseif item.login_row then
                    self:showLoginDialog(key)
                elseif item.logout_row then
                    self:_confirmLogout(key, jsKey)
                elseif item.url then
                    self.infoMessage(_("在浏览器中打开注册/登录：")
                        .. "\n" .. item.url
                        .. _("\n（KOReader 无内置浏览器：请到手机上用系统浏览器完成，"
                            .. "或改用账号登录/参数配置。）"))
                elseif item.clear_row then
                    UIManager:close(menu_self)
                    UIManager:show(require("ui/widget/confirmbox"):new{
                        text = _("清除该源的全部本地数据？\n"
                            .. "登录态、token、参数都会回到初始状态。"),
                        ok_text = _("清除"),
                        ok_callback = function()
                            self:_guard(_("清除本地数据"), function()
                                self:_srcdata():clear(jsKey)
                                self:invalidateSource(key)
                                self.infoMessage(_("已清除 ") .. tostring(key))
                            end)
                        end,
                    })
                elseif item.remove_row then
                    UIManager:close(menu_self)
                    self:_confirmRemoveSource(key)
                end
            end)
        end,
    }
    UIManager:show(menu)
end

return Browser
