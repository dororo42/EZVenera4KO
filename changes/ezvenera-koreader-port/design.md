# 设计：EZVenera for KOReader（G2/G3）

> 状态：G2/G3 PASSED（2026-09-20）
> 需求：specs/requirements.md；本文回答"怎么实现"。

## 1. 组件与边界

```
KOReader (LuaJIT, 单线程, UIManager 事件循环)
└── ezvenera.koplugin/                    ← 本插件（唯一信任边界内的组件）
    ├── _meta.lua / main.lua              → 生命周期 + 菜单（全部普通菜单项）
    ├── settings.lua                      → LuaSettings 封装（settings/ezvenera.lua）
    ├── proxyconf.lua                     → 代理状态机：存/取/校验/应用/测试 [R2]
    ├── netclient.lua                     → 插件专用 HTTP 层，per-request proxy [R2/R3]
    ├── runtime/
    │   ├── jshost.lua                    → quickjs-ng FFI：runtime/ctx/eval/job泵/回调桥 [R6]
    │   ├── bridge.lua                    → sendMessage 分发表（Lua handlers）[R3]
    │   ├── convert.lua                   → OpenSSL EVP cdef 扩展 + 纯Lua回退 [R3.3]
    │   ├── cookies.lua                   → cookie jar（域后缀/路径匹配/过期）
    │   ├── htmlparse.lua                 → (M2) HTML→DOM + CSS 选择器子集
    │   ├── sources.lua                   → 源文件仓库：index/install/update/remove [R3.4]
    │   └── browser.lua                   → 浏览 UI：源列表/搜索/详情/章节 [R3.5]
    ├── reader.lua                        → (M1) ImageViewer 惰性页流 + 全刷抖动 [R4]
    ├── vendored/
    │   └── init.js                       → EZVenera assets/init.js 原样 vendor (GPL-3.0)
    └── lib/libquickjs.so                 → 构建产物（不入库）

src/koreader-plugin/remoteinput.koplugin/  ← 【已删除 2026-09-22】原扫码远程输入插件（ADR-007 已 superseded）
    ├── main.lua / remoteinput.lua        → 入口 + facade（消费方 pcall(require, "remoteinput")）
    ├── qrcode.lua                        → 纯 Lua QR 编码器（ISO 18004 v1-4/EC L）
    ├── server.lua                        → 临时 HTTP 服务（luasocket 非阻塞 + 一次性 token）
    ├── qrwidget.lua                      → QR 自绘控件（blitbuffer）
    └── api.lua                           → 编排（依赖全部注入，可测）
```

外部依赖（全部 KOReader 内建，零新二进制）：`socket.http`/`ssl.https`、`socketutil`、`LuaSettings`、`UIManager`、`ImageViewer`、`ffi`、OpenSSL libcrypto（monolibtic 内）、`json`（KOReader 内建模块）；remoteinput 另用 `luasocket TCP 监听`（KOReader 内建 socket 库）。

## 2. 数据流

```
用户浏览 → sources.js(QuickJS) ←init.js(shim)→ sendMessage(msg) → [C bridge] → bridge.lua
   → handler: http  → netclient.lua → socket.http/ssl.https(+proxy) → 响应表
   → handler: convert → convert.lua → libcrypto EVP / 纯Lua → 字节串
   → handler: html   → htmlparse.lua → 句柄表（M2）
返回：bridge 组装结果 → JS Promise resolve（job 泵推进）
```

**异步模型**（关键设计）：JS 侧 `sendMessage` 立即返回 Promise；Lua handler 同步或异步完成，结果经 `resolvePending(id, json)` eval 回注；`jshost:poll()` 由 `UIManager:scheduleIn(0.05, …)` 自循环泵 `JS_ExecutePendingJob`，直到无 job 且无 pending 请求时停止。阻塞型 socket 调用短超时（connect 5s / total 30s）避免卡 UI（K4 单核，无并发 socket；M2 再评估 httpasync 化）。

## 3. 关键机制设计

### 3.1 代理（R2，本里程碑核心）
- 存储：`settings/ezvenera.lua`：`proxy_enabled`(bool)、`proxy_url`(string, **默认空串**，2026-09-20 修订：预置内网 IP 不入仓、真机首配——审查 L5)、`proxy_apply_global`(bool, 默认 false)。
- 校验：`proxyconf.validate(url)` 要求 `scheme∈{http,https?}` + host + 数字 port（复用 `socket.url.parse` 语义，纯 Lua 可测）。
- 应用：
  - 插件层（默认总是）：netclient 每请求注入 `proxy=`；HTTPS 用 LuaSec `tunnel/CONNECT` 路径（`ssl.https` 的 proxy 支持，若环境缺失则自实现 CONNECT 封装，代码预留 `https_via_proxy` 抽象）。
    【审查 H1 修订（2026-09-20 独立报告，已对照 luasocket v3.0.0/master 原文）】**禁用时绝不能向 luasocket 传空串 proxy**——空串为真值会进入代理分支，`socket.url.parse("")` 明确返回 nil → 索引崩溃（默认配置下全部桥接请求必挂）。实现改为：非空 URL 才写 `reqt.proxy`；强制直连 = 请求期临时清空 `mod.PROXY`（覆盖 NetworkMgr 全局值）+ 请求后立即恢复；`proxy=nil` 保持原生全局语义。
  - 全局层（用户开关）：`NetworkMgr:setHTTPProxy(url|nil)` 同步写 `socket.http.PROXY` 并持久化（注意该路径只影响 socket.http——文档明示局限）。
- 测试：GET `http://www.msftconnecttest.com/connecttest.txt`（或用户可改的探测 URL，默认备选 `http://www.gstatic.com/generate_204`），显示状态码+耗时。
- 菜单（全部普通项）：`启用代理[checked_func]`、`编辑代理地址(callback→InputDialog)`、`恢复默认地址`、`测试代理`、`同时应用于 KOReader 全局[checked_func]`。

### 3.2 JS 宿主桥（R3/R6）
- FFI cdef：quickjs 最小面（`JS_NewRuntime/NewContext/Eval/FreeValue/ExecutePendingJob/…`）+ `JS_NewCFunction` 注册 `sendMessage`（C 函数指针经 `ffi.cast`）；消息体走 JSON 字符串（避免 JSValue↔Lua 深度 marshal，第一版原则：**跨桥只传 JSON 与字节数组（`__bytes_<id>` 侧车表）**）。
- 【S2/T19 落地修订（2026-09-21）】注册层必须经**真 C shim**（`shim/ezvbridge.c` → `lib/libezvbridge.so`，`scripts/build-shim.sh`）——审查 M1 证实 LuaJIT FFI 回调按值返回 JSValue（聚合体）全架构文档明确不支持，纯 FFI 注册路线废弃。现行架构：C 侧 `JS_NewCFunction` 注册 `__ezv_post`、`JS_NewStringLen` 包装按值返回；回调经 JSContext opaque 存取（每上下文独立）；Lua 侧回调签名降为纯指针 `const char* (*)(void*, const char*)`（LuaJIT 支持范围），回调体整体 pcall。C shim 的 DT_NEEDED 由 patchelf 统一改写为 `libquickjs.so`（quickjs-ng CMake 产物 SONAME 为 libqjs.so.0）。
- `init.js` vendored：其中 `sendMessage` 被 EZVenera 注入为绑定；KOReader 侧以同名全局 JS 函数替代注入：`function sendMessage(m){ return Bridge.post(JSON.stringify(m)) }`，`Bridge.post` 为 C 注册函数。
- 字节语义（2026-09-20 修订，审查 M3）：JS↔Lua 的 ArrayBuffer 统一经纯 base64 标记 `{__bytes_b64 = "..."}` 传递（**放弃原 `__bytes_take(id)` 侧车表方案**——跨桥无状态、实现更薄）。JS→Lua：glue 在 `JSON.stringify` 前遍历消息，把 `ArrayBuffer`/`TypedArray`（含 byteOffset 视图）替换为标记表；Lua→JS：glue 解析响应后递归把标记还原为 `ArrayBuffer`。Lua 侧约定见 bridge.lua `b64wrap/b64unwrap`。
- 存储：`data/<key>.json`（与 EZVenera 同布局，便于日后互迁移），经 LuaSettings? 否——直接 json 文件 + `json.encode/decode`（KOReader 内建 json 模块；宿主测试注入桩）。

### 3.3 convert（R3.3）
- 后端选择：`ffi.load("koreader-monolibtic")`? 实际 KOReader 已加载内建库；优先 `ffi.load("crypto")` → 失败则试 monolibtic → 失败则纯 Lua 回退（base64/hex 即够 md5 后续补）。cdef 扩展 EVP：`EVP_aes_128/256_cbc/cfb8/ofb/ecb` + `EVP_EncryptInit_ex/Update/Final_ex` + `EVP_md5/sha1/sha256/sha512` + `HMAC()`。
- **无填充语义**：EVP 默认 PKCS7 padding → `EVP_CIPHER_CTX_set_padding(ctx, 0)` 强制关闭；CFB8/OFB 为流模式天然无填充。
- GBK：P2（iconv/lua-iconv 不保证在设备上可用；先返回明确错误）。

### 3.4 HTML（M2）
- 首选：vendor 纯 Lua HTML 解析器（如 lua-htmlparser 风格）+ 自实现选择器子集（tag/#id/.class/[attr]/后代/子代/逗号分组/:first/:last/:nth-child 基础）。
- 验收锚点：用 ehentai/copy_manga 真实页面样本做选择器结果快照比对（fixture 入 test/fixtures）。

### 3.5 阅读器（R4）
- `reader.lua`：复制 opdspse 模式——页表 metatable 惰性下载→`RenderImage:renderImageData`→`ImageViewer{fullscreen, with_title_bar=false, images_list_nb}`。
- 降采样：下载字节经 mupdf 解码后 `Mupdf.scaleBlitBuffer` 到 ≤800px 宽再入 viewer；单页解码字节硬上限（如 12MB）防 OOM。
- 翻页全刷：监听 viewer 翻页/或包装其 onShow→`UIManager:setDirty(nil, "full", nil, true)`（dithered full）。

### 3.6 扫码远程输入（remoteinput.koplugin，2026-09-20 增量）
- 动机：K4 虚拟键盘输入慢；同时要求天然适配 KOReader 安卓平板（触屏）。
- 流程：InputDialog「扫码远程输入」按钮 → 发现本机局域网 IP + 生成一次性 token → luasocket 绑定动态端口（`"*", 0`）→ `UIManager:scheduleIn` 非阻塞轮询（不卡 UI）→ qrcode.lua 生成二维码自绘展示 → 手机扫码在局域网页面输入 → POST `/submit?t=TOKEN` 回填 `dialog:setInputText`。
- 安全边界：一次性 token（URL 携带，错误 token 403）+ 动态端口；二维码关闭/超时即销毁服务；仅局域网可达，不做公网穿透。
- 触屏中性：全 UI 仍是普通菜单项 + 标准对话框（ADR-005 不被触碰）；触屏设备上同一按钮同样可用。
- 验证：纯 Lua QR 编码器经 zxing-cpp 真解码 7/7 ALL OK（原 tools/qr_verify.py，**已随 remoteinput 删除清理**，lupa 渲染→解码闭环）。

### 3.7 源索引与本地源（R3.4，M2；2026-09-20 用户确认）
- 默认索引：`https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/index.json`（EZVenera 官方源托管仓库）。索引 schema = 数组 `[{name, fileName, key, version, description?}]`；下载 URL = 索引基址（可配置，默认 `https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/`）+ `fileName`。K4 直连 GitHub 大概率需代理（netclient per-request 代理已覆盖）或切换 jsdelivr CDN 基址 `https://cdn.jsdelivr.net/gh/WEP-56/EZvenera-config@main/`。
- 索引 URL 可在菜单配置（编辑索引入口 → InputDialog，可直接用 remoteinput 扫码输入）。
- 本地源：`<data>/ezvenera/index/` 目录下任意 `*.json`（与官方 index.json 同 schema）参与合并展示，同 `key` 冲突时**本地条目优先**；另支持直接选择本地 `.js` 文件安装。删除本地目录中的 json 即可移除对应本地条目。
- 安装/更新仍然走确认对话框（R7.2）；安装时记录 `key/version/来源(索引URL或本地)/文件sha256` 到已安装清单，更新时展示版本差异。

## 4. ADR

### ADR-001 JS 引擎 = quickjs-ng（嵌入 .so + LuaJIT FFI）
- 备选：duktape（无 async/await，**排除**）、TSTL 转译（逐插件永久脆弱，**排除**）、Rust boa（重、慢、拖 Rust 工具链，**排除**）。
- 决策理由：唯一能原生跑原版 ES2020 插件生态的低风险路径；纯 C 可进 koxtoolchain。
- 后果：需维护 FFI 绑定与 promise 泵；内存限制用 JS_SetMemoryLimit。

### ADR-002 vendor EZVenera `init.js`（而非重写 JS shim）
- 理由：1520 行 API shim 是兼容性契约本体；重写=重造 quirk。GPL-3.0 兼容（本项目同样 GPL-3.0）。
- 后果：上游更新需手动同步；保留来源声明。

### ADR-003 插件自带 HTTP 层 + per-request 代理（不依赖 NetworkMgr:setHTTPProxy）
- 证据：原生实现只设 `socket.http.PROXY`（manager.lua:680-689），ssl.https/turbo/httpasync 均不过代理。
- 决策：netclient 对 http 传 `proxy=`，https 走 CONNECT 隧道路径；全局应用做成用户可选开关。
- 后果：与系统代理设置并存但互不污染（默认）。

### ADR-004 Rust 推迟（P2/可选）
- 证据：koreader-base 单体库已捆绑 OpenSSL+完整图像栈；Rust `-gnu` 目标要求 glibc≥2.17，需走 musl softfp 静态 cdylib（双 libc 坑）。
- 决策：不进入关键路径；保留 `rust/` 配方（musleabi + panic=abort + 按需 cdylib）与空骨架。
- 再评估触发条件：FS 抖动/降采样在真机实测 >300ms/页，或 AES 大图流实测不足。

### ADR-005 K4 无长按红线：代理等关键配置仅用普通菜单项
- 证据：hold 在 K4 = ScreenKB+Press（2024.07+）但不可发现；原生代理设置依赖 hold_input。
- 决策：本项目所有菜单项禁用 hold 依赖（脚本断言）；文本输入走 InputDialog（虚拟键盘）+ 文档指引。

### ADR-006 页图显示 = ImageViewer 图像列表 + 惰性 metatable + dithered 全刷
- 理由：复用 KOReader 现成非触屏键位/缩放/进度条；opdspse 是仓库内验证过的范式。
- 后果：依赖 renderimage/mupdf 路径；WebP 由 mupdf 覆盖（AC 待真机验证 webp 源）。

### ADR-007 扫码远程输入 = 独立插件 + 弱依赖接入（而非集成进 EZVenera）
> **【SUPERSEDED 2026-09-22】** 用户决策：扫码远程输入**整体删除**（取代本 ADR 的拆仓方案）。
> remoteinput.koplugin 已从仓库移除，本节保留仅作决策轨迹。现行约束见 AGENTS.md 红线 #5。
> 本节提及的 tools/qr_verify.py 已随删除清理，不再存在。
- 备选：集成进 ezvenera.koplugin（**排除**：QR/HTTP 服务与漫画源域无关，核心复杂度膨胀；weread.K4 等其他插件无法复用）。
- 决策：`remoteinput.koplugin` 独立交付；消费方以 `pcall(require, "remoteinput")` 弱依赖 + `available()` 探测，缺失时优雅回退纯键盘输入。KOReader 为启用的插件注册 `package.path`，跨插件 require 天然可行。
- 后果：facade（remoteinput.lua）持注入实例，测试与消费方共用；EZVenera 侧改动收敛为 proxyconf 一处按钮注入（~20 行）；协议/端口/token 语义全部内聚在 remoteinput。

## 5. 可靠性 / 安全 / 运维

- 全部网络调用短超时 + 失败 InfoMessage；插件内任何错误被 pluginloader 沙箱捕获不致崩 KOReader。
- 源安装/更新需确认对话框；索引 URL 可配置。
- 日志：`log` handler 写 `<data>/ezvenera.log`（轮转 1MB），含插件名不凭据。
- GPL-3.0：vendored init.js 与本项目源码同仓同许可；README 声明。
