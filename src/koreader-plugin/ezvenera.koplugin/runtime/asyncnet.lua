--[[
EZVenera for KOReader — runtime/asyncnet.lua
非阻塞网络任务的调度骨架（r10 M1 第 1 步）。

为什么需要它（M0 真机实测，2026-09-27，见 AGENTS.md 对应条）：
  桥是同步 C 回调（jshost 的 `__ezv_post`），Lua 协程**不能跨 C 帧挂起**，
  所以「一次请求阻塞 4s × 2 次尝试 = 最坏 ~8s 无法取消」这件事没法靠挪标志
  解决——UI 事件在阻塞期间根本不派发。唯一的出路是把阻塞变成「试一下 →
  没数据就把控制权交回 UIManager 节拍 → 下一拍再试」。

本文件只负责「交回控制权」的机制与预算，不碰传输本身：
  * `submit(body, on_done)`：body 在协程里跑，任意处可以 yield；
  * `tick()`：UIManager 节拍调它，按墙钟预算逐个 resume 在飞任务；
  * `AsyncNet.pause(io, obj, mode)`：io 层的等待原语——非阻塞 select 轮询，
    没就绪就 yield；单片（一次 resume 内）超预算也 yield。
  切片预算是**必须**的：真机实测轮询本身亚毫秒，但一次 resume 里如果数据
  一直就绪（快速链路读整张图），循环就不会自己让出，冻结只是换了地方。

真机两条硬约束（写死在这里，别让调用方重新踩）：
  1. `socket.select` 的集合元素必须是带 `getfd` 的对象，数字 fd 直接抛
     `attempt to index a number value`；
  2. 本机 LuaSocket 3.1.0 没有 `settimeouts`，也没有 `socket.tryconnect`，
     非阻塞一律靠 `settimeout(0)` + select 轮询。
]]

local AsyncNet = {}
AsyncNet.__index = AsyncNet

-- 同时在飞的上限：低配设备（安卓 6 / 1.5GB）先稳后快；并发带来的内存与
-- 代理链路压力在 M0 里没有测过，放大到 >2 需要独立数据。
AsyncNet.DEFAULT_MAX_INFLIGHT = 2
-- 单个任务在一次 resume 里允许占用的墙钟（秒）。5s ANR 预算下留足余量：
-- 2 个在飞任务 × 该值 + JS 泵 ≪ 5s。
AsyncNet.DEFAULT_SLICE_SEC = 0.030

local function defaultNow()
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.gettime) == "function" then
        return socket.gettime()
    end
    return os.time() + (os.clock() % 1)
end

--- 非阻塞 select 包装：返回 readable, writable, err。
--- obj 集合里的元素是「带 getfd 的对象」（约束 1）。
local function pollNow(selectFn, readSet, writeSet)
    local ok, r, w, e = pcall(selectFn,
        (readSet and #readSet > 0) and readSet or nil,
        (writeSet and #writeSet > 0) and writeSet or nil,
        0)
    if not ok then return nil, nil, tostring(r) end
    return r or {}, w or {}, e
end

function AsyncNet.new(deps)
    deps = deps or {}
    local o = setmetatable({}, AsyncNet)
    o.now = deps.now or defaultNow
    o.select = deps.select or function(rs, ws, timeout)
        local socket = require("socket")
        return socket.select(rs, ws, timeout)
    end
    o.max_inflight = deps.max_inflight or AsyncNet.DEFAULT_MAX_INFLIGHT
    o.slice_sec = deps.slice_sec or AsyncNet.DEFAULT_SLICE_SEC
    -- 单次系统调用的等待上限（交给 job 的 io._wait_sec）。不存这一行，
    -- submit 里的 `self.wait_sec or 4` 会永远退回 4，配置形同虚设。
    o.wait_sec = deps.wait_sec
    o._jobs = {}          -- id → job
    o._order = {}         -- 稳定的提交顺序（round-robin 用）
    o._nextId = 1
    o._stats = { resumes = 0, yields = 0, polls = 0, max_resume_sec = 0 }
    return o
end

--- 等待原语（协程内调用）。io = 任务句柄（由 submit 注入），
--- obj = 可用于 select 的对象（socket 或 LuaSec conn），
--- mode = "read" | "write" | "both"。
--- 返回 true = 已就绪；false, why = 放弃（why = "cancelled"|"poll-error"）。
function AsyncNet.pause(io, obj, mode)
    local job = io._job
    if not job then return false, "no-job" end
    if job.cancelled then return false, "cancelled" end
    if not obj then return false, "no-selectable-object" end
    mode = mode or "read"
    local tries = 0
    while true do
        if job.cancelled then return false, "cancelled" end
        tries = tries + 1
        io._polls = (io._polls or 0) + 1
        local want_r = (mode == "read" or mode == "both")
        local want_w = (mode == "write" or mode == "both")
        local r, w, perr = pollNow(io._select,
            want_r and { obj } or nil, want_w and { obj } or nil)
        if perr and type(perr) == "string" and not r then
            return false, "poll-error: " .. perr
        end
        local rdy_r = r and #r > 0
        local rdy_w = w and #w > 0
        -- both 按「任一就绪」判：TLS 握手期就是这个形状（M0 实测 want() 会
        -- 给方向，但调用方未必拿到，兜底要能用）
        if (want_r and want_w and (rdy_r or rdy_w))
                or ((rdy_r or not want_r) and (rdy_w or not want_w)) then
            return true, tries
        end
        if io._deadline and io._now() > io._deadline then
            return false, "wait-timeout"
        end
        -- 交回控制权：这一 yield 就是「UI 能呼吸」的唯一机会
        coroutine.yield()
        if job.cancelled then return false, "cancelled" end
    end
end

--- 单个 socket 操作的「重试直到不阻塞」包装（io 层用）。
--- fn 必须是非阻塞形态（底层 settimeout(0)），返回 luasocket/LuaSec 的
--- (ok, err, part) 形状；本函数只在「现在没数据」时接管等待。
--- block_err = 哪些错误串算「稍后再试」。
function AsyncNet.retry(io, obj, mode, fn, blockErr)
    local job = io._job
    local deadline = io._now() + (io._wait_sec or 4)
    while true do
        -- 取消检查在 fn() **之前**：作业被丢弃后不会再有节拍来 resume 它，
        -- 所以这里也是「不再对已取消的连接发起系统调用」的唯一保证点
        if job and job.cancelled then return nil, "cancelled" end
        local ok, err, part = fn()
        if ok then return ok, err, part end
        local e = tostring(err)
        local blocking = false
        for _, pat in ipairs(blockErr or { "timeout", "wantread", "wantwrite" }) do
            if e:find(pat) then blocking = true break end
        end
        if not blocking then return ok, err, part end
        if io._now() > deadline then
            -- 总超时：把最后一次的「现在没数据」原样交回，调用方能报出真实错因
            return nil, err
        end
        local mode2 = e:find("wantwrite") and "write"
            or (e:find("wantread") and "read" or (mode or "both"))
        -- 把总超时交给 pause：否则等待循环只认「数据来了没」，对端不吭声
        -- 就等于每个在飞任务多占一拍才被发现过期
        local prev_deadline = io._deadline
        io._deadline = deadline
        local ready, why = AsyncNet.pause(io, obj, mode2)
        io._deadline = prev_deadline
        if not ready then
            if why == "wait-timeout" then return nil, err end
            return nil, why or "wait-failed"
        end
    end
end

local Job = {}
Job.__index = Job

function Job:cancel()
    if self.cancelled then return end
    self.cancelled = true
    -- 取消由 UI 线程发起（协程正挂在 yield 上，够不着自己的 fd），
    -- 所以「关掉这条连接」必须在这里同步做掉。协程随后被 resume 一次
    -- 走 unwind，pause/retry 都会立刻返回 "cancelled"，不会再发系统调用。
    if self.cleanup then
        local ok, e = pcall(self.cleanup, self)
        if not ok then
            self.cleanup_error = tostring(e)
        end
    end
end

function Job:status()
    return self.done and self.result or coroutine.status(self.co)
end

--- 提交一个任务。body(io) 在协程里执行；yield 由 tick 续。
--- on_done(ok, result_or_err) 在任务结束的那一拍末尾同步调用。
function AsyncNet:submit(body, on_done)
    local io = {
        _select = self.select,
        _now = self.now,
        _wait_sec = self.wait_sec or 4,
        _polls = 0,
    }
    local job = setmetatable({
        id = self._nextId,
        io = io,
        on_done = on_done,
        cancelled = false,
        done = false,
        queued_at = self.now(),
    }, Job)
    self._nextId = self._nextId + 1
    io._job = job
    job.co = coroutine.create(function()
        local ok, a, b = pcall(body, io)
        return ok, a, b
    end)
    if #self._order >= self.max_inflight then
        -- 超上限：排队。入 _waiting，等 _order 有空位再进。
        self._waiting = self._waiting or {}
        self._waiting[#self._waiting + 1] = job
        return job
    end
    self._jobs[job.id] = job
    self._order[#self._order + 1] = job.id
    return job
end

--- 一拍：按墙钟预算推进在飞任务。返回 { active, started, finished }。
function AsyncNet:tick(budget_sec)
    local budget = budget_sec or self.slice_sec
    local slice_deadline = self.now() + budget
    local started, finished = 0, {}
    local i = 1
    while i <= #self._order do
        local id = self._order[i]
        local job = self._jobs[id]
        if not job then
            table.remove(self._order, i)
        else
            local t0 = self.now()
            local ok, ret_ok, ret_a, ret_b = self:_resume(job)
            local dt = self.now() - t0
            local st = self._stats
            st.resumes = st.resumes + 1
            if dt > st.max_resume_sec then st.max_resume_sec = dt end
            started = started + 1
            if not ok then
                -- 协程内 pcall 已经收过错误；走到这里说明 pcall 本身没兜住
                job.done, job.ok, job.result = true, false, tostring(ret_ok)
                finished[#finished + 1] = job
                table.remove(self._order, i)
                self._jobs[id] = nil
            elseif coroutine.status(job.co) == "dead" then
                -- 任务体约定：返回 (value, err)。value 为 nil/false 判失败，
                -- 成功时 on_done 拿 value，失败时拿 err（缺 err 就用 value
                -- 本身，`return nil, "reason"` 是最常见写法）。
                local good = ret_ok and ret_a ~= nil and ret_a ~= false
                job.done, job.ok = true, good
                job.value, job.err = ret_a, ret_b
                job.result = good and ret_a or (ret_b ~= nil and ret_b or ret_a)
                finished[#finished + 1] = job
                table.remove(self._order, i)
                self._jobs[id] = nil
            else
                i = i + 1
            end
            if self.now() > slice_deadline then break end
        end
    end
    -- 空出来的槽位补给排队任务
    while self._waiting and #self._order < self.max_inflight do
        local job = table.remove(self._waiting, 1)
        if not job then break end
        if not job.cancelled then
            self._jobs[job.id] = job
            self._order[#self._order + 1] = job.id
        end
    end
    for _, job in ipairs(finished) do
        if job.on_done then
            local oke, e = pcall(job.on_done, job.ok, job.result)
            if not oke then
                self.errors = (self.errors or 0) + 1
                self.last_error = tostring(e)
            end
        end
    end
    return { active = #self._order, started = started,
             finished = #finished, queued = self._waiting and #self._waiting or 0 }
end

--- 一拍里每个任务只推进一次 resume：任务体内的 `pause` 是「轮询一次，没就绪
--- 就 yield」的形态，所以节拍周期就是 I/O 等待的粒度（M0 实测轮询本身亚毫秒）。
--- 数据就绪时同一拍里 `pause` 会直接返回，任务继续往下跑，直到下一次让出。
--- 返回值必须原样带出（协程体的 (value, err) 全靠这条链回到 tick）。
function AsyncNet:_resume(job)
    local ok, pcall_ok, a, b = coroutine.resume(job.co)
    if not ok then return false, a end
    return true, pcall_ok, a, b
end

function AsyncNet:pending()
    local n = #self._order
    if self._waiting then n = n + #self._waiting end
    return n
end

function AsyncNet:stats()
    return self._stats
end

--- 任务全部丢弃（引擎重建 / 测试收尾用）：只丢引用，socket 由持有方关。
function AsyncNet:abortAll()
    local n = 0
    for _, job in pairs(self._jobs) do job:cancel(); n = n + 1 end
    for _, job in ipairs(self._waiting or {}) do job:cancel(); n = n + 1 end
    self._waiting = {}
    return n
end

return AsyncNet
