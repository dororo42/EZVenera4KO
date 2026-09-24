-- R6 回归锁：阅读页取图曾调用 netclient:get(...)——NetClient 上没有这个方法，
-- pcall 把它吞成 nil，ImageViewer 取到 nil 页后由 ImageWidget 抛
-- error("cannot render image")，整个 KOReader 被 CrashReportActivity 终止
-- （真机 /data/data/org.koreader.launcher.fdroid/cache/crash.log 实证）。
-- 静态校验浏览层引用的 netclient 方法真实存在、取图走带代理与 cookie 的通道。
local NetClient = require("netclient")

local tests = {}

local function pluginSource(mod)
    local p = package.searchpath(mod, package.path)
    assert(p, "cannot locate module source: " .. mod)
    local f = io.open(p, "rb")
    assert(f, "cannot open " .. p)
    local src = f:read("a")
    f:close()
    return src
end

function tests.browser_calls_only_real_netclient_methods()
    local src = pluginSource("browser")
    local seen = 0
    for name in src:gmatch("netclient:(%a[%w_]*)") do
        seen = seen + 1
        assert(type(NetClient[name]) == "function",
            "browser.lua calls netclient:" .. name .. "() which does not exist")
    end
    assert(seen > 0, "no netclient calls found in browser.lua (matcher broken?)")
    return true
end

function tests.browser_image_fetch_uses_request_channel()
    local src = pluginSource("browser")
    assert(src:find("netclient:request", 1, true),
        "image fetch must go through netclient:request")
    assert(not src:find("netclient:get", 1, true),
        "netclient:get is not part of the NetClient API")
    -- 图片请求必须继承代理设置与 cookie jar，否则开代理后图片全直连失败
    assert(src:find("isProxyEnabled", 1, true),
        "reader must honour the proxy setting")
    assert(src:find("headerFor", 1, true),
        "reader must attach cookie jar headers")
    return true
end

function tests.browser_failed_page_gets_placeholder_not_nil()
    local src = pluginSource("browser")
    assert(src:find("placeholderPage", 1, true),
        "reader needs a placeholder page when an image fails")
    -- 占位页必须每页新建：viewer 以 image_disposable 语义在换页时 free
    -- 当前 BB，复用同一对象会造成二次释放
    assert(src:find("BB.new", 1, true),
        "placeholder must allocate a fresh blitbuffer")
    return true
end

return tests
