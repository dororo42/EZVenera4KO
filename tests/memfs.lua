-- 测试共用：内存文件系统（runtime/downloader.lua 的 deps.fs 契约）
-- files/dirs 两张表，接口语义与 Downloader.makeFs()（lfs + io）一致：
-- 目录不存在时 list 返回 nil，remove 目录非空即失败。

return function()
    local files, dirs = {}, {}
    local fs = { writes = 0 }
    function fs.mkdir(path)
        local acc = path:sub(1, 1) == "/" and "" or nil
        for seg in path:gmatch("[^/]+") do
            acc = (acc == nil) and seg or (acc .. "/" .. seg)
            dirs[acc] = true
        end
        return true
    end
    function fs.write(path, bytes)
        files[path] = bytes
        fs.writes = fs.writes + 1
        return true
    end
    function fs.read(path) return files[path] end
    function fs.exists(path) return files[path] ~= nil or dirs[path] == true end
    local function parent(p) return p:match("^(.*)/[^/]*$") end
    local function base(p) return p:match("[^/]+$") end
    function fs.list(dir)
        if not dirs[dir] then return nil end
        local seen, out = {}, {}
        for p in pairs(files) do
            if parent(p) == dir and not seen[base(p)] then
                seen[base(p)] = true
                out[#out + 1] = base(p)
            end
        end
        for p in pairs(dirs) do
            if parent(p) == dir and not seen[base(p)] then
                seen[base(p)] = true
                out[#out + 1] = base(p)
            end
        end
        table.sort(out)
        return out
    end
    function fs.remove(path)
        if files[path] ~= nil then files[path] = nil return true end
        if dirs[path] then
            for p in pairs(files) do
                if p:sub(1, #path + 1) == path .. "/" then return false end
            end
            dirs[path] = nil
            return true
        end
        return false
    end
    fs.state = { files = files, dirs = dirs }
    return fs
end
