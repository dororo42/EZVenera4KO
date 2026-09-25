--[[
EZVenera for KOReader — corefix.lua

【真机闪退根因（2026-09-23 两次实证）】崩溃报告里唯一一条 Lua 错误是
    frontend/ui/widget/booklist.lua:47: attempt to compare nil with number
即 KOReader 自带“按上次阅读时间排序”的比较器 `a.attr.access > b.attr.access`
对 attr 缺失的条目（未挂载的卡、拿不到 atime 的 FUSE/sdcardfs 路径）没有保护。
它发生在文件浏览器/历史记录列表重绘时——我们的菜单一关，后面重绘就打死整个
应用，用户看到的却是“点漫画源闪退”。

我们不改 KOReader 的文件（升级即失效、且要 root 写私有目录），而是在插件启动
时把 collates 里的比较器换成 nil 安全版：出错就退化为按路径排序，列表照常显示。
]]

local CoreFix = {}
CoreFix.__index = CoreFix

--- 把任意“取属性再比较”的比较器包成不会抛错的版本。
--- 返回的函数保持 (a, b) → boolean 契约；抛错时退化为路径/标题字典序，
--- 保证仍是严格弱序（同一条目对同一集合结果一致，排序不会抖动）。
function CoreFix.safeComparator(fn)
    return function(a, b)
        local ok, res = pcall(fn, a, b)
        if ok then return res == true end
        local ka = tostring(a and (a.path or a.text) or "")
        local kb = tostring(b and (b.path or b.text) or "")
        return ka < kb
    end
end

--- 同理包住“取属性生成显示文本”的函数：属性缺失时显示空串而不是崩掉列表。
function CoreFix.safeTextFunc(fn)
    return function(item)
        local ok, res = pcall(fn, item)
        if ok and res ~= nil then return res end
        return ""
    end
end

--- 就地给一份 collates 表装上保护。幂等：已包装过的不再套第二层。
--- 返回被处理的 sorter 名列表。
function CoreFix.harden(collates)
    local done = {}
    if type(collates) ~= "table" then return done end
    for name, collate in pairs(collates) do
        if type(collate) == "table" then
            if type(collate.init_sort_func) == "function"
                and not collate._ezvenera_hardened then
                local orig = collate.init_sort_func
                collate.init_sort_func = function(cache)
                    local fn, new_cache = orig(cache)
                    if type(fn) ~= "function" then return fn, new_cache end
                    return CoreFix.safeComparator(fn), new_cache
                end
                for _, key in ipairs({ "mandatory_func", "optional_func" }) do
                    if type(collate[key]) == "function" then
                        collate[key] = CoreFix.safeTextFunc(collate[key])
                    end
                end
                collate._ezvenera_hardened = true
                table.insert(done, tostring(name))
            end
        end
    end
    table.sort(done)
    return done
end

--- 启动时调用一次。返回 (installed, detail)；任何异常都不外抛。
function CoreFix.install()
    local ok, BookList = pcall(require, "ui/widget/booklist")
    if not ok or type(BookList) ~= "table" then
        return false, "booklist unavailable"
    end
    local okh, done = pcall(CoreFix.harden, BookList.collates)
    if not okh then return false, tostring(done) end
    if #done == 0 then return false, "nothing to harden" end
    return true, table.concat(done, ",")
end

return CoreFix
