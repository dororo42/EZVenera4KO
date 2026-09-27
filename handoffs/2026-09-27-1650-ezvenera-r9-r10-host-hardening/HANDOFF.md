# Handoff: EZVenera_KO r9+r10 收口（搜索/续传/非阻塞化/阅读器内存）

## 元数据

- Created: 2026-09-27 16:50
- Source agent: Qoder 主 agent（本轮 = A/B 对照实验结案 + 阅读器内存修复 + r9/r10 收口会话）
- Project: <项目根>（本文件按仓库脱敏口径书写，不含本机绝对路径 / 局域网地址 / 凭据）
- Branch: main，HEAD: 78838c7（工作树干净，无未提交项）
- OS: win32（Git Bash + tools/.venv）

### 交接链

- **Continues from**: `handoffs/2026-09-23-0905-ezvenera-android-engine-apk/`
- **2026-09-24 → 09-27 的逐轮决策与真机数字全部在 `AGENTS.md` 的「当前 Handoff」条目里**（r9 报告对账、htmlparse 选择子、bridge 日志降级、豆包源装机与证书判定、r10 M0/M1/M2/M3 全链、C-call boundary 收口、receive prefix 真机回归、双重主机图片 500、本轮 A/B + RSS）。本文只写"接手立刻要用"的当前态，不重复那些证据。

## 当前状态摘要（一段话版）

**功能面**：安卓平板 13 源装机全链路可用（源列表/主页/分类/详情/章节/阅读/前后章/下载/缓存/离线/收藏/历史/搜索/引擎状态），搜索与分类的「不可用」真因是 `htmlparse.lua` 的 CSS 属性选择子只实现 `[a=v]` 一种形状（恒 0 命中且不报错），已补齐运算符全集并真机端到端取证。**离线下载**已改成取消/失败保留字节 + 断点续传（manifest 加 `complete` 位），未完成章由 `listPartials()` 在缓存界面单独列出。**内存**：阅读器逐出解码 BB 改成当场 `:free()`（旧写法只丢引用等 LuaJIT 终值器），真机连续翻页 510 页 RSS 从「一路涨到 2.13GB」变成 157MB 平台。**崩溃核实**：A/B 对照实验（A=零本项目代码的上游解码/ImageViewer 压测，B=真实阅读器自动翻页 600 页）**全部零崩溃、tombstone 恒 10 条**，那批 libluajit `mfree` unlink SIGSEGV 与阅读时长/翻页无因果，属稀有事件。**r10 非阻塞网络栈**（asyncnet + 桥 promise + await 跨拍）代码全部落地并由 457 单测钉住，但 `async_http` **默认关**：真机证伪了 M1 前提——本机 luasocket 的 `http.request` 是 C 闭包，可暂停 conn 的四个钩子全在 C 帧之内，`attempt to yield across C-call boundary` 无法绕过；用户已拍板停在这里，不再自写 HTTP/1.1 客户端。闸门：**457 单测 / 语法 17 / no-hold 17 文件 / vendored `f0b2c8413d438bd2…` 全绿**。

## 最近提交（本轮及上一轮，HEAD 起）

- 78838c7 docs(agents): A/B 对照实验结案 + 逐出 BB 显式回收的实测数字
- 75ce1af fix(reader): 逐出解码 BB 时当场回收，并挡住屏幕上那一页
- b9837d2 docs(agents): r10 M0–M3 全链、真机 C-call boundary 收口与 receive 回归
- c95bc6a feat(net): r10 非阻塞网络栈（asyncnet + 桥 promise + await 跨拍），默认关
- 4d445fe / 483e440 docs(agents): r9 建议报告逐条对账 + 搬运源体量实测
- 5bc5dbb fix(downloader): 取消/失败保留已下页并断点续传，缓存界面可见未完成章
- e0074e5 / 7bf8811 fix(htmlparse): 补齐 CSS 属性选择子运算符，修搜索/分类空列表
- 97dab92 / 8469fb2 fix(jshost): bridge 流水账降级为 dbg，只留 http 桥错误在 warn

## 关键落点（按"要动它就先看这里"排）

| 文件 | 作用 / 不得破坏的等价性 |
|---|---|
| `runtime/asyncnet.lua` | 「把控制权交回 UI」的机制层，不碰传输。写死两条真机硬约束：`socket.select` 只吃带 `getfd` 的对象、非阻塞一律 `settimeout(0)`。`Job:cancel()` **同步**跑 cleanup（协程挂在 yield 上够不着 fd） |
| `netclient.lua` | `_tlsConn` 的 conn 包装：**`receive(pattern, prefix)` 两个入参必须逐个显式转发**（LuaJIT 5.1 语义，嵌套闭包里拿不到 `...`），丢了 prefix  luasocket 的状态行两步读就拿到 `"1.1 200 OK"` → 每个 https 请求都报失败。同步/异步共用 `_httpOpts()` 与 `httpFinish()` |
| `runtime/bridge.lua` | `handlers.http` 在 `async_http` 开时返回 `{__pending=id}`，结果走 `_http_ready`；**网络失败一律按值投递**（`status=nil`），绝不变成桥错误/reject（源判的是 `status !== 200`） |
| `runtime/jshost.lua` | 泵顺序钉死：`_tickNet` → `_deliverHttp` → `_drainJobs` → `_pollTimers`（兑现必须排在排空前，否则源的 continuation 再等一整拍）；`jsLiteral()` 负责把响应 JSON 嵌进 JS 源码（裸 LF 不转义 = 静默丢结果）；bridge 流水账走 dbg，`http` 桥错误走 warn |
| `browser.lua` `_awaitSourceAsync` | await 槽位化（`__ezv_ret[slot]` + 用完 delete），一拍一次 `engine:pump()`；续体全部过 `self:_guard`（错误冒到主循环 = 整应用闪退） |
| `browser.lua` `servePage` 逐出循环 | `bbStillReferenced()` 判据（`viewer.image` + 占位页）+ `attempts` 上限 + **显式 `doomed:free()`**。屏幕上那一页永不被 free，两种时机都要挡（换页瞬间 `imageviewer.lua:481` 先取新页、`:485` 才改游标） |
| `browser.lua` `fetchImageBytes` | 图片路由「探测—确认」：超时只标记可疑，探测也失败就收回；只有「代理失败 + 直连成功」才钉死直连。绝对 URL 被源再拼一次主机时**先于网络**判掉 |
| `runtime/htmlparse.lua` | `compoundTokens()` 括号感知、`matchAttr()` 覆盖 `= *= ^= $= ~= |=` 与裸 `[attr]`；`child` 标记落在自己那一跳上 |
| `runtime/downloader.lua` | manifest 的 `complete` 位（缺行=完整，兼容旧文件）；未完成章不进 `list()`、不计体积、不能离线打开，由 `listPartials()` 单独列出可删 |
| `tests/tlsfake.lua` | 本地全栈端到端的假 socket/ssl 栈（**会真把响应体喂给 `reqt.sink`**），共享助手 `BODY/jsonEnc/jsUnescape` 都在这。假 conn 已按 luasocket 的 `receive` 三形态补齐 |

## 验证与真机状态

- **闸门命令**：
  `export PYTHONIOENCODING=utf-8; tools/.venv/Scripts/python.exe scripts/run_tests.py`（457 例，基线恒含 1 条 `libcrypto` SKIP）
  `… scripts/check_syntax.py`（17/17）· `… scripts/check_no_hold.py`（17 文件干净）· `… scripts/verify_vendored.py`（`f0b2c8413d438bd2…`）
  按文件过滤：`run_tests.py reader_cache`
- **平板（`<设备序列号>`，`adb devices` 只有一台 / Android 6 / KOReader v2026.07.1）**：`plugins/ezvenera.koplugin` 下 **17 个 .lua 与源仓逐文件 md5 一致**（含本轮 `browser.lua` = `20b009da…`）。`async_http` 默认关 ⇒ 设备行为与 M3 之前逐字节一致。
- **探针已清理**：`plugins/ezvab.koplugin`、`/sdcard/koreader/ezv_ab/`（模式文件 + A 组用的 12 张页图）已删；重启后 logcat 只剩常规加载行，`Fatal signal` / `ANR in` 0 条，`/data/tombstones` 与基线逐行 diff 为空。用户自装的 `pinyinplus` / `weread` / `webbrowser.zip` 未触碰。
- **A/B 复现方式**（仓库外 `ezv_scratch/crash67/abprobe/` + `run_ab.sh`）：写 `/sdcard/koreader/ezv_ab/mode` 为 `a1` / `a2` / `b1 <秒>` / `b2 <秒>` / `b3 <秒> <每N页完整GC>`，重启 KOReader 后探针 8s 自跑；日志用**侧过滤 + 后台抓取**（华为上 `logcat -d` 事后取会掉 94% 的行）。
- **本地证据天花板**（不得夸大）：本地 LuaJIT **没有** luasocket/LuaSec ⇒ 真 socket 层只能真机证；本地最高一层是 tlsfake 串起真 NetClient+AsyncNet+Bridge+JsHost；JS 的 Promise 兑现语义用真 node 跑 `.mjs` 点验（脚本在仓库外 `ezv_scratch/m2/`）。

## 已知限制（不做假象）

1. 明文 `http` 源与自定义 transport 不经 `_tlsConn.create` ⇒ 异步帮不上，仍阻塞（真机实测 xmanhua 一次搜索 1269ms 期间心跳 0 次）。
2. 单页最坏取消延迟 ~8s（block 超时 4s × 2 次尝试），socket 级即时中断属 r10 M4，**已判定不做**。
3. 大图首拍偶发 `wantread` / `sink timeout`（~7s），第二拍重试即 200——r9 的两次尝试链兜住，属已知形状。
4. `tests/tlsfake.lua` 的假栈每次事务结束就 `close` ⇒ 本地测不到隧道复用，那条由 `test_netclient` 的「异步建隧同步复用」钉住。
5. Kindle 4 冻结（恢复时按零 patchelf 配方重编引擎）。

## 待办（接手后的优先级）

- **#65 发布 r9/r10**：走仓库外脱敏暂存树（`ezv_scratch/make_pub_stage.py`，**跑前先清空暂存树**）→ 逐 blob 对拍（差异只允许落在被脱敏改写的 `*.md`）→ `commit-tree` 快进挂远端 HEAD（**不强推**）→ CI `test` + `engine-build-dryrun` 双绿。公开仓当前 `main = 2e6d67c`（r8）。
- **#64 同步构建机母本 `doubaomanhua.js`** 的双重主机修复（平板已改，母本未改 ⇒ 下次整包推送会把缺陷带回）。
- **#28 jshost 容忍 ESM 包装**（`export default` / `import`）；**#29 explore 成员**（移植源只有发现、无分类）；**#30 移植包 21 个语法错误源**。
- 用户侧三件（不是我们的活，但要在状态汇报里挂着）：吊销已用过的 PAT；开 GitHub Support 工单对 `EZVenera4KO` 做对象 GC 并确认 fork；轮换签名 keystore 与构建机口令（换签名 ⇒ 平板须 `adb uninstall` 重装，`/sdcard/koreader` 数据保留）。
- 已明确**不做**：T20 `modifyImage`（零消费者）、图片首拍超时形状改动、r10 M1'/M4、`categoryComics.optionLoader` 动态筛选、扫码远程输入（红线，不得恢复）。
