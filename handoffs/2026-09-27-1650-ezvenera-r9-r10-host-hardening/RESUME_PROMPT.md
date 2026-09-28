# EZVenera for KOReader — Resume Prompt（2026-09-27 r9+r10 收口终态）

你接手一个项目：**EZVenera for KOReader**（在 KOReader 的 LuaJIT 里运行 Venera/EZVenera JS 漫画源插件的移植层；优先安卓平板 Android 6 / arm64，Kindle 4 暂缓）。

## 项目状态

- **功能面全绿**（真机 13 源装机清单，2026-09-26 起）：源列表 / 主页 / 分类 / 详情 / 章节 / 阅读 / 前后章切换 / 整章离线下载 / 下载与缓存管理 / 离线打开 / 收藏 / 历史 / 搜索 / 引擎状态。
- **r9 那轮**（源仓 `5bc5dbb` 等）：取消与失败**保留已下页并断点续传**（manifest `complete` 位），未完成章在缓存界面单独列出；htmlparse 的 CSS 属性选择子补齐运算符（修掉搜索/分类"恒 0 命中且不报错"）；bridge 流水账降级为 dbg。
- **r10**（源仓 `c95bc6a`）：非阻塞网络栈全链落地（`runtime/asyncnet.lua` + 桥 promise + `browser.lua` await 跨拍 + 泵自适应周期），但 **`async_http` 默认关**——真机证伪了 M1 前提：本机 luasocket 的 `http.request` 是 C 闭包，四个可暂停钩子全在 C 帧之内，`attempt to yield across C-call boundary` 绕不过。**用户已拍板停在这里**，不自写 HTTP/1.1 客户端、不做 M4。
- **本轮内存修复**（源仓 `75ce1af`）：阅读器逐出解码 BB 从"只丢引用等 LuaJIT 终值器"改成**逐出当场 `:free()`**，前置 `bbStillReferenced()`（`viewer.image` + 占位页）与 `attempts` 上限。真机连续翻页 510 页 RSS 由「每页 ~5.2MB 单调涨到 2.13GB」变成 **157MB 平台**。
- **#72 / T26 降采样解码（2026-09-28，源仓 `de437a7`，用户指令「先执行 B 然后 A」「真机点验，然后看结果提交，不加开关」）**：A = 新增 `Browser:imageDims()` 只读容器头部取宽高，`servePage` **仅当页宽 > 面板宽**才把 `(req_w, req_h)` **成对**传给 `renderImageData`（上游 `scaleBlitBuffer` 缺任一入参就不缩放）；B = BB 逐出保留字节软上限（12MB）+「至少常驻 2 页」硬下限，`page_bb_bytes` / `page_bb_min_pages` 两个把手可由构造参数注入。**没有新增任何设置项**。真机（面板 1200×1920）：dims 13 样本 **mismatch=0**、宽图 1600 驻留比值 56%、三章真实阅读器 **`clamp生效= 0`**（⇒ 对实测真页是空操作）、RSS 138~147MB 全程平、`Fatal signal`/`ANR in` 0 条。B 的硬下限在 ≤6MB/页 形状上 **binding 不到**（同章 min 设 1/2/4 解码次数全为 8/10 访问页），保留为显式不变量。C（钉 800）判定不做。
- **崩溃核实结案**：A/B 对照实验（A=零本项目代码的上游 `renderImageData`+`ImageViewer` 压测；B=真实阅读器自动翻页 600 页）**全部零崩溃、`/data/tombstones` 恒 10 条**。libluajit `mfree` unlink 那批 SIGSEGV 与翻页/阅读时长无因果，属稀有事件。
- **回归基线**：**461** 单测 / 语法 17 / no-hold 17 文件 / vendored `f0b2c8413d438bd2…`（本地基线恒含 1 条 `libcrypto` SKIP，不算红）。
- **平板状态**：`plugins/ezvenera.koplugin` 17 个 .lua 与源仓逐文件 md5 一致（2026-09-28 #72 落地后再核一次，`browser.lua` = `5015d9f3…`）；一次性探针（`ezvab.koplugin` + `/sdcard/koreader/ezv_ab/`、`ezvq.koplugin` + `/sdcard/koreader/ezv_q/`）已删，重启后 logcat 只剩常规加载行（`EZVQ` 0 条、KOReader 侧 error 0 条、`Fatal signal`/`ANR in` 0 条、tombstone 恒 10）。`/sdcard/koreader/ezv_bundle/` 是产品导入扫描目录（`main.lua:715`）加用户自己 09-26 导入的文件，**不是残留探针，别删**；`sources/*.bak-*` 与 `installed.json.bak-doubao` 同理归用户。

## 用户既定决策（必须遵守）

1. **优先安卓平板；Kindle 4 冻结**（恢复时按零 patchelf 配方重编引擎）。
2. **ADR-005 禁 hold 依赖**：Kindle 4 全部配置入口只用普通 `callback`（CI `scripts/check_no_hold.py` 扫所有 `.koplugin`）。
3. **ADR-002 不动 `vendored/init.js`**：sha256 锁定、`.gitattributes` 钉 LF；要改必须同步 `.sha256` 与版权头（本轮 r10 的 promise 通道刻意做成"init.js 一字节没动"）。
4. **ADR-003 自带 HTTP 代理层**，不依赖 `NetworkMgr:setHTTPProxy`（那只影响 `socket.http`，HTTPS 不过代理 ⇒ 不能换 `turbo/httpasync` 底座）。
5. **扫码远程输入（remoteinput）已删除，不得恢复**；**凭据一律不入仓、不入文档、不入脚本**，命令行里不出现明文 token。
6. **r10 不再往下做**（M1'/M4 明确不做）；**T20 `modifyImage` 不做**（装机源与 init.js 零消费者）；图片首拍 `wantread`/`sink timeout` 的已知形状不改。
7. 真机上的源/插件由用户自己管：**探针用完必删**，用户自装的 `pinyinplus` / `weread` / `webbrowser.zip` 不碰。

## 你的第一个动作

1. 读 `AGENTS.md`（红线 + 「当前 Handoff」里 09-24→09-27 的逐轮证据）→ `handoffs/2026-09-27-1650-ezvenera-r9-r10-host-hardening/HANDOFF.md`（**本份为最新**）。
2. 跑四闸门：`export PYTHONIOENCODING=utf-8; tools/.venv/Scripts/python.exe scripts/run_tests.py`（应 **461**/0）+ `check_syntax.py` + `check_no_hold.py` + `verify_vendored.py`。
3. **#65 发布已完成（2026-09-27）**：公开 `main` 快进 `2e6d67c` → `2ec26cc`（r9 = 源仓 `75ce1af`+`78838c7`+`0d11a59` 合集），CI `test` + `engine-build-dryrun` 双绿，`init.js`/`.sha256` blob 与源仓相同，未强推。要复用时走 `ezv_scratch/pub_snapshot2.sh`：先在公开仓本地 clone `fetch main` 拿 parent（源仓对象库里没有它），**在导出 `GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE` 之前**取源仓侧的值，逐 blob 校 vendored 与路径集合，`--push` 才动远端。发布树的 `AGENTS.md` 落后一次属正常。**#65 追加（2026-09-28）**：r10 快照已推送，公开 `main` = `d1c492f`（源仓 `de437a7`+`ff88f05`+`0ab4212`+`2e2d781`，全量树 104 文件、与 r9 差异只落在 8 个文件），CI `test` + `engine-build-dryrun` 双绿、未强推。本轮新踩到的操作事实：**本机 `github.com:443` 直连被 reset/超时（`api.github.com` 仍通），`pub_snapshot2.sh` 前要 `export http_proxy=https_proxy=http://<局域网代理>`**（CONNECT 隧道，凭据不外露）；脱敏复核改成**只对本次改动的文件做新旧命中差集**（`ezv_scratch/scan_changed_files.py`，判据 `added=0`），整树扫描会连历史里已发布的良性命中一起报。
4. **项目侧待办已归零（2026-09-28 复核）**：#71 关闭、#72 已落地（见上）、#28/#29 已关单、#64/#30 按用户决策**移交漫画源团队**（不排期；宿主侧等价防御 #66 + R3.1 在位，平板那份 `doubaomanhua.js` 15783 B 实测**守卫已在**，缺的只是构建机母本）。唯一悬着的是**发布**——**已于 2026-09-28 完成**：本轮提交（`de437a7` + `ff88f05` + `0ab4212` + `2e2d781`）作为 r10 快照快进推上公开 `main`=`d1c492f`，CI 双绿、逐 blob 对拍通过、未强推。已判**不做**：r10 M1'/M4、T20/T21、C 方案钉 800、`categoryComics.optionLoader`。

## 不得破坏的等价性（改到这些文件前先看）

- `netclient.lua` 的 `_tlsConn` conn 包装：**`receive(pattern, prefix)` 两个入参都要显式转发**（丢 prefix ⇒ 状态行两步读拿到 `"1.1 200 OK"` ⇒ 每个 https 请求报失败）；LuaJIT 5.1 语义下嵌套闭包里拿不到 `...`。
- 同步与异步共用 `_httpOpts()` + `httpFinish()`；**网络失败一律按值投递**（源判 `status !== 200`），绝不能变成桥错误/reject。
- `JsHost:pump()` 顺序：`_tickNet` → `_deliverHttp` → `_drainJobs` → `_pollTimers`（兑现排在排空前）。
- `browser.lua` 逐出循环：屏幕上那一页（`viewer.image`，换页瞬间它还是上一页）与占位页永不 `free()`；逐出条件同时受**字节软上限**与 **`BB_MIN_PAGES` 硬下限**约束（去掉任一条都会把在用那页 free 掉，两条单测做过变异复验）。
- `browser.lua` 降采样：`(req_w, req_h)` **必须成对**传给 `renderImageData`（上游 `scaleBlitBuffer` 缺任一入参就直接不缩放，只传宽等于没传）；宽高只能来自 `imageDims()` 这类**读头部**的判据，不能"先解出来再看"（TurboJPEG/libwebp 分支都是全解再缩，钱已经花掉了）。
- `browser.lua` 图片路由：超时只标可疑，探测也失败就收回标记，只有"代理失败 + 直连成功"才钉死直连。

## 已知限制（别当新缺陷查）

1. 明文 `http` 源与自定义 transport 仍阻塞（真机实测一次搜索 1269ms 期间心跳 0 次）。
2. 单页最坏取消延迟 ~8s（4s block 超时 × 2 次尝试），即时中断属已取消的 M4。
3. 本地 LuaJIT **没有** luasocket/LuaSec ⇒ 真 socket 层只能真机证；本地最高层是 `tests/tlsfake.lua` 串起真 NetClient+AsyncNet+Bridge+JsHost，且假栈每次事务结束就 close（隧道复用在本地测不到）。JS 语义用真 node 跑 `.mjs` 点验。
4. Java 层「KOReader crashed」对话框**也会由未捕获 Lua 错误弹出**（无 tombstone）⇒ 定性前必读 `NativeThread` 行；`UIManager:close(w, true)` 的 `true` 被当 refreshtype，会在 `uimanager.lua:1082` 把应用杀掉。
5. 华为平板上 `logcat -d` 事后取会掉约 94% 的行 ⇒ 必须边跑边按 tag 过滤抓。

## 交付要求

每个模块收尾必须：闸门四件全绿 + 说明本地/真机各自的证据边界 + 真机点验用真实入口（`继续上次阅读` / 点菜单，不是自建捷径）+ 探针删除并重启确认。涉及真机或翻开关的动作先等用户点头。
