# EZVenera for KOReader — Resume Prompt（2026-09-27 r9+r10 收口终态）

你接手一个项目：**EZVenera for KOReader**（在 KOReader 的 LuaJIT 里运行 Venera/EZVenera JS 漫画源插件的移植层；优先安卓平板 Android 6 / arm64，Kindle 4 暂缓）。

## 项目状态

- **功能面全绿**（真机 13 源装机清单，2026-09-26 起）：源列表 / 主页 / 分类 / 详情 / 章节 / 阅读 / 前后章切换 / 整章离线下载 / 下载与缓存管理 / 离线打开 / 收藏 / 历史 / 搜索 / 引擎状态。
- **r9 那轮**（源仓 `5bc5dbb` 等）：取消与失败**保留已下页并断点续传**（manifest `complete` 位），未完成章在缓存界面单独列出；htmlparse 的 CSS 属性选择子补齐运算符（修掉搜索/分类"恒 0 命中且不报错"）；bridge 流水账降级为 dbg。
- **r10**（源仓 `c95bc6a`）：非阻塞网络栈全链落地（`runtime/asyncnet.lua` + 桥 promise + `browser.lua` await 跨拍 + 泵自适应周期），但 **`async_http` 默认关**——真机证伪了 M1 前提：本机 luasocket 的 `http.request` 是 C 闭包，四个可暂停钩子全在 C 帧之内，`attempt to yield across C-call boundary` 绕不过。**用户已拍板停在这里**，不自写 HTTP/1.1 客户端、不做 M4。
- **本轮内存修复**（源仓 `75ce1af`）：阅读器逐出解码 BB 从"只丢引用等 LuaJIT 终值器"改成**逐出当场 `:free()`**，前置 `bbStillReferenced()`（`viewer.image` + 占位页）与 `attempts` 上限。真机连续翻页 510 页 RSS 由「每页 ~5.2MB 单调涨到 2.13GB」变成 **157MB 平台**。
- **崩溃核实结案**：A/B 对照实验（A=零本项目代码的上游 `renderImageData`+`ImageViewer` 压测；B=真实阅读器自动翻页 600 页）**全部零崩溃、`/data/tombstones` 恒 10 条**。libluajit `mfree` unlink 那批 SIGSEGV 与翻页/阅读时长无因果，属稀有事件。
- **回归基线**：457 单测 / 语法 17 / no-hold 17 文件 / vendored `f0b2c8413d438bd2…`（本地基线恒含 1 条 `libcrypto` SKIP，不算红）。
- **平板状态**：`plugins/ezvenera.koplugin` 17 个 .lua 与源仓逐文件 md5 一致；一次性探针（`ezvab.koplugin`、`/sdcard/koreader/ezv_ab/`）已删，重启后 logcat 只剩常规加载行。

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
2. 跑四闸门：`export PYTHONIOENCODING=utf-8; tools/.venv/Scripts/python.exe scripts/run_tests.py`（应 457/0）+ `check_syntax.py` + `check_no_hold.py` + `verify_vendored.py`。
3. **头号待办 = #65 发布**：走仓库外脱敏暂存树 `ezv_scratch/make_pub_stage.py`（**跑前先清空暂存树**，脚本的删除步骤是空操作）→ 暂存树与源仓逐 blob 对拍（差异只允许落在被脱敏改写的 `*.md`，`vendored/init.js` 与 `.sha256` 必须同 sha）→ `commit-tree` 挂公开 `main`（当前 `2e6d67c`）快进推送（**不强推**）→ CI `test` + `engine-build-dryrun` 双绿 → 回写 AGENTS.md 的发布状态并提交。
4. 次号待办：**#64** 把双重主机修复同步回构建机母本 `doubaomanhua.js`（平板已改，母本未改 ⇒ 下次整包推送会把缺陷带回）；然后 #28 / #29 / #30。

## 不得破坏的等价性（改到这些文件前先看）

- `netclient.lua` 的 `_tlsConn` conn 包装：**`receive(pattern, prefix)` 两个入参都要显式转发**（丢 prefix ⇒ 状态行两步读拿到 `"1.1 200 OK"` ⇒ 每个 https 请求报失败）；LuaJIT 5.1 语义下嵌套闭包里拿不到 `...`。
- 同步与异步共用 `_httpOpts()` + `httpFinish()`；**网络失败一律按值投递**（源判 `status !== 200`），绝不能变成桥错误/reject。
- `JsHost:pump()` 顺序：`_tickNet` → `_deliverHttp` → `_drainJobs` → `_pollTimers`（兑现排在排空前）。
- `browser.lua` 逐出循环：屏幕上那一页（`viewer.image`，换页瞬间它还是上一页）与占位页永不 `free()`。
- `browser.lua` 图片路由：超时只标可疑，探测也失败就收回标记，只有"代理失败 + 直连成功"才钉死直连。

## 已知限制（别当新缺陷查）

1. 明文 `http` 源与自定义 transport 仍阻塞（真机实测一次搜索 1269ms 期间心跳 0 次）。
2. 单页最坏取消延迟 ~8s（4s block 超时 × 2 次尝试），即时中断属已取消的 M4。
3. 本地 LuaJIT **没有** luasocket/LuaSec ⇒ 真 socket 层只能真机证；本地最高层是 `tests/tlsfake.lua` 串起真 NetClient+AsyncNet+Bridge+JsHost，且假栈每次事务结束就 close（隧道复用在本地测不到）。JS 语义用真 node 跑 `.mjs` 点验。
4. Java 层「KOReader crashed」对话框**也会由未捕获 Lua 错误弹出**（无 tombstone）⇒ 定性前必读 `NativeThread` 行；`UIManager:close(w, true)` 的 `true` 被当 refreshtype，会在 `uimanager.lua:1082` 把应用杀掉。
5. 华为平板上 `logcat -d` 事后取会掉约 94% 的行 ⇒ 必须边跑边按 tag 过滤抓。

## 交付要求

每个模块收尾必须：闸门四件全绿 + 说明本地/真机各自的证据边界 + 真机点验用真实入口（`继续上次阅读` / 点菜单，不是自建捷径）+ 探针删除并重启确认。涉及真机或翻开关的动作先等用户点头。
