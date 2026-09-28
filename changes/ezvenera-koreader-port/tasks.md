# 任务分解：EZVenera for KOReader（G4）

> 依赖有序；每项含 REQ 锚点与验证方式。完成标准：验证方式通过 + 对抗审查过。
> 图例：✅ 本轮已完成 · 🔶 本轮部分完成 · ⬜ 待做

## M0 脚手架（本轮）

| # | 任务 | REQ | 验证 | 状态 |
|---|---|---|---|---|
| T1 | git 仓库 + 目录结构 + .gitignore（reports/ 不入库） | — | git status | ✅ |
| T2 | G0 四路研究报告（reports/） | — | 评审 | ✅ |
| T3 | specs/requirements.md（G1） | 全部 | 评审 | ✅ |
| T4 | changes/ proposal+design+tasks（G2-G4） | 全部 | 评审 | ✅ |

## M1 插件骨架 + 代理（本轮，P0 主交付）

| # | 任务 | REQ | 验证 | 状态 |
|---|---|---|---|---|
| T5 | 插件骨架：_meta.lua/main.lua/菜单树（无 hold 依赖） | R1.1-2, R5.1 | 静态走查 + hold-grep 断言 | ✅ |
| T6 | settings.lua（LuaSettings 封装 + 默认值） | R1.3, R2.2 | 单测 | ✅ |
| T7 | proxyconf.lua（校验/应用/测试/菜单） | R2.1-2.6 | 单测（校验+选择逻辑） | ✅ |
| T8 | netclient.lua（http+https per-request proxy、超时、UA、重定向） | R2.3, R3.2 | 单测（fake socket） | ✅（UA=默认注入 `Dart/3.5 (dart:io)`，2026-09-20 兑现 L7；CONNECT 路径**真机已验**（2026-09-26/27 两次探针：同一章节图直连 200、经代理 200），旧「待验」作废） |
| T9 | 测试基建：python+lupa 驱动 LuaJIT 单测 | — | 本机跑通 | ✅ |
| T10 | scripts/fetch+build-quickjs.sh（kindle5 交叉 + x86_64 开发构建） | R6.1, R6.4 | 脚本审查 + bash -n | ✅（2026-09-20 修复：fetch 默认 tag 404 → pin v0.17.0 + sha256 校验；build 显式 BUILD_SHARED_LIBS=ON） |
| T11 | rust/ 配方骨架（不接关键路径，cargo check 通过） | ADR-004 | cargo check + 文档 | ✅ |
| T12 | vendored init.js 入仓 + 许可声明 + sha256 锁 | ADR-002 | verify_vendored.py 通过 | ✅ |
| T13 | jshost.lua（FFI cdef + 加载探测 + 优雅降级） | R1.4, R6.2 | 无库时降级单测 + 真机 eval | ✅（**状态更正 2026-09-27**：真机 dlopen/init/eval 全链已由安卓引擎随 APK 分发收口（AGENTS「T-S3」条，用户实测零崩溃），旧「S2 冒烟待做」作废） |
| T14 | bridge.lua + convert.lua + cookies.lua + storage + 测试 | R3.2-3.3 | 单测覆盖 bridge/convert/cookies/storage | 🔶（原 ✅ 语义修正 2026-09-20：此前为**桩覆盖**；NIST/RFC 真向量由 `tests/test_convert_real.lua` 承载，CI 装 libssl-dev 后生效，无 libcrypto 环境自动 SKIP。**2026-09-27 装机 15 源取证**：`"convert"` 调用 **0 次** ⇒ GBK/RSA/ofb8 三个桩分支零消费者，维持不做） |
| T15-T18 | — | — | （M2 已落地，见 git 历史） | ✅ |
| T25 | UX 导航改造：标题栏返回箭头 + 盖栈不拆栈 + 面包屑（17 处菜单统一 _navMenu；× = 逐层返回，根层退出；审查报告 §10 O1-O4） | R5.1 | 321 单测（含盖栈契约钉住）+ 真机走查待做 | ✅ |

## 增量交付：remoteinput.koplugin 扫码远程输入（2026-09-20）

> 需求升级：K4 输入不便 + 天然适配触屏平板（KOReader Android）。评估结论：**独立插件 + 弱依赖接入**（ADR-007），不集成进 EZVenera。

| # | 任务 | REQ | 验证 | 状态 |
|---|---|---|---|---|
| R1 | 评估独立插件 vs 集成 + EZVenera 触屏适配核查 | — | 评估结论 + `_meta.lua` 文案触屏中性化 | ✅ |
| R2 | 【已删除 2026-09-22】qrcode.lua 纯 Lua QR 编码器（remoteinput 随用户决策整体移除；验证工具 tools/qr_verify.py 已清理） | — | 历史记录：zxing-cpp 真解码 7/7 ALL OK | ⛔ 已删除 |
| R3 | server.lua 临时 HTTP 服务（luasocket 非阻塞 + scheduleIn 轮询 + 一次性 token/403 + 超时自毁） | — | fake socket 单测 10 项 | ✅ |
| R4 | qrwidget.lua 自绘 + api.lua 编排 + main.lua/remoteinput.lua facade | — | 单测 + 语法检查 | ✅ |
| R5 | EZVenera 弱依赖接入（proxyconf InputDialog 注入「扫码远程输入」按钮 + setInputText 回填） | — | 弱依赖回退单测（无插件时安全） | ✅ |
| R6 | 全量回归 + 红线复检（check_no_hold 扩为全插件扫描） + 文档同步 | — | 109 通过/0 失败；hold clean（15 文件）；vendor 校验过 | ✅ |

## Spike S2（quickjs 实机冒烟）

| # | 任务 | REQ | 验证 | 状态 |
|---|---|---|---|---|
| T-S2a | 二进制桥真机冒烟（审查 M3）：glue 的 ArrayBuffer↔base64 转换已实现（jshost QUICKJS_GLUE，Node 侧行为测试 10/10 通过） | R3.2 | 真机日志 + 加密图片源样例 | ✅（**2026-09-27 核销**：真机 13 源端到端全链路可用（源列表→阅读→下载→离线），图片解码/桥消息全过；「加密图片源样例」由 `modifyImage` 零消费者取证取代——装机 15 源该 API 0 命中，见 T20） |
| T-S2b | quickjs 实机冒烟：libquickjs.so 交叉编译 + eval/cdef/回调 ABI 验证（T13 收尾） | R6 | 真机状态页 | ✅（**2026-09-27 核销**：安卓 arm64 走零 patchelf 配方 + 随 APK 注入（AGENTS「T-S3」条），真机状态页报 `engine.initialized=true`；kindle5 softfp 产物已入库但设备冻结） |
| T-S2c | 桥接 C shim（审查 M1 关闭路径）：真 C 层包装 JSValue 按值返回，Lua 侧回调降为纯指针 `const char* (*)(void*, const char*)`，JSContext opaque 存回调（多实例安全） | R6.2 | scripts/build-shim.sh（host/x86_64/kindle + --test）；patchelf 改写 NEEDED libqjs.so.0→libquickjs.so；sha256 `28e06340…4580a` | ✅ |

## M3 加固（2026-09-27 逐条定性；状态列本轮补上）

| # | 任务 | REQ | 验证 | 状态 |
|---|---|---|---|---|
| T20 | modifyImage 像素管线（RGBA uint32 语义 + PNG 编码）+ 快照回归 | R3.6 | 位级一致 fixture | ⛔ 不做（装机 15 源仅 `ManHuaGui.js:1086` 的**注释**命中，真消费者 0；`handlers["image"]` 维持返回明确错误） |
| T21 | GBK 解码（lua-iconv 探测 / 内置表裁剪） | R3.3 | 样本比对 | ⛔ 不做（装机 15 源 `gbk` 0 命中、`"convert"` 调用 0 次） |
| T22 | httpasync 化 + 多页预取（性能） | R4 | 真机计时 | ⛔ 不做（r10 完整走过一轮：真机 C-call boundary 证伪 M1 前提，用户拍板停在 M3、`async_http` 默认关；**F4 前提已用本机上游检出处处核实**——`frontend/httpasync.lua` 全文 `proxy` 0 命中，唯一代理入口是 `frontend/ui/network/manager.lua:682` 写**全局** `http.PROXY`，正是 ADR-003 排除的形状；`newsdownloader.koplugin/epubdownloadbackend.lua:686` 确实用 `httpasync.fetch_many` 并发，报告 F3 至此复核完毕） |
| T23 | Rust 优化再评估（按 ADR-004 触发条件） | ADR-004 | 基准数据 | ⬜ 未触发（ADR-004 的触发条件=基准数据，至今没有需要它的性能缺陷） |
| T24 | MRPI 打包 + 发布流程 + README 安装文档 | — | 打包产物在模拟器装载 | 🔶 半（安卓侧发布链已成型：仓库外脱敏暂存树 + `commit-tree` 快进 + Release 资产；MRPI/KOReader 模拟器一支随 Kindle 4 冻结挂起） |
| T26 | 阅读器按面板宽降采样解码（原 `browser.lua` 三参调用 ⇒ 原生分辨率解码） | R4.2 | 同一真图三种入参的 RSS/耗时对照 + 单测 + 真机点验 | ✅ 已落地（2026-09-28，方案 A + B；真机 dims mismatch=0、clamp 只对宽图接管、真页 `clamp生效= 0`，B 的硬下限在 ≤6MB/页形状上 binding 不到但作为显式不变量保留；C 钉 800 判定不做。详见「T26 落地（A+B）与真机点验」节，四闸门 461/17/17/vendored 绿） |
| T27 | WebP/GIF 页图在真机能否解出 | R3.6, design.md:123 | 真机探针喂一条真 `.webp` 字节 | ✅ 已验（2026-09-27，真机 ezvwp 探针，已删）：**WebP/GIF 全解得开，宿主无需改动** |

### T26/T27 真机实测（2026-09-27，安卓平板 `<DEVICE-SERIAL>`，KOReader `v2026.07.1`，屏 1200×1920）

探针 `ezvwp.koplugin`（仓库外 `ezv_scratch/webp_scale/`，跑完即删；样本=平板上真实页图 + PIL 生成的动图/宽图）。
定责办法：上游后端失败只打 `logger.dbg`（常规 logcat 看不见），所以**逐后端点名调用**（`renderWebpImageDataWithLibwebp`
/ `renderGifImageDataWithGifLib` / `renderJpegImageDataWithTurboJpeg` / `renderImageDataWithMupdf`），不劫持上游 logger。

**T27 结论：能解，且两条后端都能解 ⇒ 零宿主改动。**

| 样本（真字节） | 通用分派 `renderImageData(data,#data,false)` | libwebp / giflib 点名 | MuPDF 兜底 |
|---|---|---|---|
| `铳梦 p004.webp` 278010B（copy_manga 画质档改写的真页） | **ok** 95ms 800×1137 stride3200 3.64MB(RGB32) | webp **ok** 79ms 同尺寸 | **ok** 61ms 2.73MB(RGB24) |
| 动图 webp（2 帧） | **ok** 88ms 1115×1600 7.14MB（=第 1 帧） | webp **ok** 88ms | **nil**（MuPDF 不解动 webp，与上游注释一致） |
| 动图 gif（2 帧） | **ok** 104ms 1115×1600 7.14MB | gif **ok** 101ms | ok 200ms |
| 静图 gif | **ok** 65ms | gif **ok** 64ms | ok 142ms |
| `want_frames=true`（我们的链路不传） | webp 帧表 2 帧 1ms（惰性）/ gif 帧表 2 帧 69ms | — | — |
| 真页 jpg 291372B | ok 24ms 1115×1600 stride3345 **5.35MB(RGB24)** | jpeg ok 22ms | ok 56ms |

- **FFI 三件套都在**：`ffi/webp` `ffi/pic` `ffi/mupdf` 均可 require；`/proc/self/maps` 里搜不到 `webp`/`gif`/`mupdf`
  是**静态链进 `libkoreader-monolibtic.so`**（logcat 有 `ffi.findlib: webpdemux` + `ffi.load: …monolibtic.so`），
  所以 maps 探测对判定「后端在不在」完全无效，只能按上表点名调用。
- **顺带抓到一条与内存直接相关的形状差**：同一像素尺寸下 **webp/gif 回 RGB32（4 字节/像素），jpeg 回 RGB24（3 字节）**
  ⇒ 1115×1600 一页 webp 是 7.14MB 而 jpeg 是 5.35MB（多 1/3），解码耗时也从 24ms 涨到 88~95ms。
  我们的 BB 预算 `BB_BUDGET=12MB`（`browser.lua:2094`）⇒ **webp 页只装得下 1 页**，逐页预取（`wantAhead`）
  对 copy_manga 这类吐 webp 的源实际失效——这是 T26 真正的缺口，不是"没降采样"。
  **（2026-09-28 更正：最后一句当时就写错了。预取走 `loadInto`，只取字节、从不解码，被逐出的是已解码 BB，
  所以代价是「回翻必重解」而不是「预取等于白做」；下面「T26 落地」节的 B 方案按这个真实形状收口，
  其名字「预算按页字节自适应/恢复 webp 预取」同样不准确，实际落点是「至少常驻 2 页」的硬下限。）**

**T26 结论：按面板宽 clamp 在当前平板上是空操作；只有「页宽 > 屏宽」时才有收益。**

单页（`ms` 为解码耗时，`bytes` 为 BB 驻留 = stride×h）：

| 样本 | 原始（现行） | clamp 到屏宽 1200 | clamp 到 800 |
|---|---|---|---|
| 真页 jpg 1115×1600 | 24ms / 5.35MB | 22ms / 5.35MB（**页宽<屏宽 ⇒ 无变化**） | 98ms / 2.76MB |
| 真页 webp 800×1137 | 95ms / 3.64MB | 62ms / 3.64MB（无变化） | 62ms / 3.64MB（无变化） |
| 宽图 jpg 1600×2300 | 54ms / 11.04MB | **218ms / 6.21MB** | 157ms / 2.76MB |
| 宽图 webp 1600×2300 | 208ms / 14.72MB | **403ms / 8.28MB** | 334ms / 3.68MB |

连解 6 页不 free（= 阅读器 BB 缓存的真实驻留形状；RSS delta 与 BB 总字节几乎 1:1 ⇒ **省的就是驻留，峰值不减**）：

| 入参 | bb_total | 6 页耗时 | RSS delta |
|---|---|---|---|
| 真页 jpg 原始/clamp1200 | 32.11MB | 137ms / 135ms | 31.13MB / 31.15MB |
| 真页 jpg clamp800 | 16.53MB | 589ms | 16.43MB |
| 宽图 原始 | 66.24MB | 319ms | 64.68MB |
| 宽图 clamp1200 | 37.26MB | **1325ms** | 36.59MB |
| 宽图 clamp800 | 16.56MB | 949ms | 16.36MB |

- 三个判据摆出来：**省内存是真的**（6 页驻留 66MB→37MB→17MB），**代价也是真的**（单页耗时 ×2~4，6 页 319ms→1325ms），
  而**放大质量**这条是硬伤：我们把 BB 表交给 `ImageViewer`（`image = page_table`，不是 function），
  上游 `ImageViewer._scaled_image_func` 只在 `image` 是函数时才生效 ⇒ 缩放图放大是从降采样后的 BB 插值，永久糊。
- ⇒ 可选口径（等用户拍板，不擅自动阅读器）：
  **A 只做「页宽 > 屏宽」才 clamp**（R4.2 的原意，宽图 6 页驻留 66→37MB，真页零影响、零质量损失）；
  **B 预算自适应**（按 `budget/页字节` 决定驻留页数而非固定 12MB，让 webp 页也能留 3 页，预取恢复有效）；
  **C 钉 800**（最省内存，但 ×4 解码 + 放大糊，当前设备上没必要）。
  **（2026-09-28 拍板：用户指令「先执行 B 然后 A」「真机点验，然后看结果提交，不加开关」⇒ A+B 已落地，C 不做；
  B 的落点与这里的描述有出入——不是「按页字节自适应预算」，而是保留字节软上限再加一条「至少常驻 2 页」的硬下限，
  且实测在 ≤6MB/页 的真页形状上 binding 不到，见下面落地节。）**
- 崩溃/ANR：整轮 `Fatal signal` 0 条、`ANR in` 0 条；探针与 `ezv_wp/` 夹具目录已删，
  重启后新进程 logcat 零条 `EZVWP`，用户自装的 `pinyinplus` / `weread` / `webbrowser.zip` 未触碰。

### T26 落地（A+B）与真机点验（2026-09-28，用户指令「先执行 B 然后 A」「真机点验，然后看结果提交，不加开关」）

改了什么（`browser.lua` 的 `_openReader`，无新增设置项）：
- **A**：新增 `Browser:imageDims(data)` —— 只读容器头部拿宽高（JPEG SOF / WebP VP8·VP8L·VP8X / GIF LSD / PNG IHDR，不解码、不联网），
  `servePage` 里 **仅当页宽 > 面板宽** 才把 `(req_w, req_h)` 成对传给 `renderImageData`（上游 `scaleBlitBuffer` 缺任一入参就直接不缩放）。
- **B**：BB 逐出保留两条线 —— 字节上限（软，12MB）+ `BB_MIN_PAGES`（硬，2 页），可由构造参数 `page_bb_bytes` / `page_bb_min_pages` 注入（测试与探针用）。

真机（`<DEVICE-SERIAL>`，面板 1200×1920，探针 `ezvq` 已删）实测：

| 用例 | 结果 |
|---|---|
| `dims`：13 张样本（8 夹具 + 5 张用户已存的真页）头部宽高 vs 实际解出的 BB 宽高 | **mismatch= 0**（逐张 `hdr= WxH decoded= WxH match= 1`） |
| `clamp`：宽图 1600×2300 | jpg 11.04MB/57ms → **6.21MB**/219ms；webp 14.72MB/244ms → **8.28MB**/403ms（比值 56%） |
| `clamp`：其余 11 张（含全部真页 800~1200 宽） | **SKIP**（判据不成立 ⇒ 一次都不 clamp，零质量损失） |
| `reader` 真实章节 ×3（xmanhua 21 页 / doubaomanhua 31 页 ×2 轮） | `clamp生效= 0`（真页宽 800/1001/1115 < 面板 1200）；每访问页解码 0.8~1.0；RSS 138~147MB 全程平；`Fatal signal` 0 / `ANR in` 0 / tombstones 恒 10 |
| `reader` 同章 A/B：`page_bb_min_pages` 1 vs 2 vs 4（默认 12MB） | 解码次数 **全为 8/10 访问页**，回翻第 4 步必重解 —— 单页 2.63MB 时字节线先 binding，硬下限不改变行为 |
| `reader` 压小预算 A/B（5MB，单页 2.63MB） | 1 页 vs 2 页下限 **同为 10/10** —— 真机正向翻页时「屏幕上那页」被 `bbStillReferenced` 保住，效果与下限 2 重叠 |
| 真机两种画质档的同一章（webp 800×1137 = 3.64MB/页 vs jpg 1115×1600 = 5.10MB/页） | 解码 9 vs 10 次 —— **差别来自源给的页字节，不是本改动**；webp 页 stride=3200（RGB32）、jpg stride=3345（RGB24），与 #71 结论一致 |

结论与口径（不夸大）：
- A 在 1200 面板上对**所有实测真页是空操作**（`clamp生效= 0` 三次独立证实），只在页宽 > 面板宽时接管，收益 56% 驻留、代价单页 +160ms —— 与 2026-09-27 的三档数字完全吻合。
- B 的硬下限在实测页形状（≤6MB/页）上 **binding 不到**：真机的免费回翻实际由既有的引用保护提供。它的价值是把「至少常驻 2 页」写成显式不变量，覆盖 #71 里那类 >6MB 的大页（1115×1600 webp = 7.14MB ⇒ 12MB 预算只留 1 页）。**不改默认预算、不加开关**，实测零回归。
- 闸门：461 单测 / 语法 17 / no-hold 17 文件 / vendored `f0b2c8413d438bd2…`；新增 4 个用例（`image_dims_reads_container_headers_without_decoding`、`only_overwide_pages_are_clamped_to_the_panel`、`bb_budget_keeps_two_webp_sized_pages_resident`、`bb_floor_at_one_page_makes_flip_back_re_decode`），后两条做过变异复验（去掉下限 / 去掉构造参数注入 ⇒ 立刻转红）。
- **C（钉 800）不做**：×2~4 解码 + 放大永久糊（我们交的是 `page_table` 表，上游 `_scaled_image_func` 不启用）。
- 对账与收尾：源仓 `de437a7`（代码 + 用例）+ `ff88f05`（文档），**公开快照 r10 已于 2026-09-28 推送**（`main`=`d1c492f`，快进、CI 双绿、逐 blob 对拍通过）。点验之后只补了一处**等价收紧**——GIF 魔数从 `find("8?a")`（Lua 里 `8?` 是「可选的 8」，实际只要求第 6 字节是 `a`）改成 `== "87a" or == "89a"`；真机样本全是 jpeg/webp ⇒ 上面每条数字都不受影响。补完后平板与源仓**逐文件 md5 全 17 个一致**（`browser.lua` = `5015d9f3…`），重启后 logcat 零条 KOReader 侧 error（只剩 `com.google.android.gms` 的 `ERR_TIMED_OUT`，与本应用无关）、`Lua error` 0 条。

## 依赖关系

T5→T6/T7→T8（骨架先行）；T9 与 T5-T8 并行；T13/T14 依赖 T10 产物（但可先用降级桩开发）；M2 依赖 M1；T20 依赖 T15；T23 依赖里程碑 M2 真机基线数据。

## 交付决策与待办（2026-09-20 17:49，用户指令）

> 详细配方与评估见 `handoffs/2026-09-20-1749-ezvenera-remoteinput-split/HANDOFF.md`。

| # | 事项 | 说明 | 验证 | 状态 |
|---|---|---|---|---|
| D1 | 两插件分别建 GitHub 仓库，暂不一起打包 | remoteinput 拆独立仓（随迁 test_qrcode/test_server/test_api/stubs_remote）；package-mrpi.sh 保持只打 ezvenera | 两仓 CI 各自绿 | ⛔ 作废（2026-09-22 用户决策删除 remoteinput，红线 5 不得恢复；发布改走单仓 + GitHub Release 资产 `ezvenera-engine-android-arm64.zip`，CI 双闸门实测绿） |
| D2 | lib/libquickjs.so 编译 | **主路线 = 北京实例 `lhins-ni6p5t1q`（ap-beijing，2026-09-20 核实：RUNNING，x86_64/Ubuntu 24.04/27GB 可用盘，⚠️ 2026-09-30 到期需续费）**，koxtoolchain kindle5 预编译工具链；上海实例已过期隔离（信息降级，仅历史参考）；备选 GitHub Actions/WSL | readelf：ARM EABI、无 Tag_ABI_VFP_args、GLIBC ≤2.12 | ✅（见下方完成记录）**⚠️ 实例 09-30 到期 = 用户侧决定续不续**；kindle5 产物已是母本，重建安卓产物另有 T-S3 零 patchelf 配方 |
| D3 | 双设备部署测试 | 安卓平板 + Kindle 4，SSH 通道；**等用户通知后执行**，凭据不入仓 | 真机冒烟：remoteinput 独立入口 → ezvenera 代理+扫码回填 → S1/S2 | 🔶（**安卓侧远超原口径**：13 源装机全链路真机验收（2026-09-26/27），代理 CONNECT 直连/经代理双 200 实测；remoteinput 那一支随插件删除作废；Kindle 4 侧随设备冻结挂起，恢复时按零 patchelf 配方重编再验收） |
| D4 | 安卓 .so spike | 一机一产物：Kindle 用 glibc/softfp 版，安卓用 **NDK bionic/arm64 版**（`aarch64-linux-android21-clang -fPIC -shared`，build-quickjs.sh 增 `android` target；若平板装的是 armeabi-v7a APK 还需 v7a 产物）；部署路径同为 `lib/libquickjs.so`（按设备分发，不需多架构加载器）；待验：KOReader Android 从用户插件目录 dlopen（W^X） | android-arm64 .so 在 KOReader Android ffi.load 成功 | ✅（**「从插件目录 dlopen」被真机否掉并已替代**：W^X 拦用户目录 .so → 改走零 patchelf 构建 + 随 APK 注入重签（AGENTS「T-S3」条），真机 dlopen/init/eval 全链稳定、用户实测零崩溃。故本项验证条件按实际落点改判） |
| D5 | 源索引确认（R3.4，M2） | 默认索引 = `https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/index.json`（schema `[{name,fileName,key,version,description?}]`，下载 = 基址+fileName，jsdelivr CDN 备选）；本地源 = `<data>/ezvenera/index/*.json` 合并、同 key 本地优先 + 本地 `.js` 直装（design §3.7） | sources.lua M2 实现后：拉取官方索引→安装→本地 json 合并用例 | ✅（四条安装路径全落地并真机验收：URL 直装 / 自定义 index.json / 本地文件 / 索引浏览；另加导入版本护栏 + `sha256` 真值 + 重名可分辨 + 回退旧版，2026-09-26） |

> **D2 完成记录（2026-09-20 19:40）**：产物已入库 `src/koreader-plugin/ezvenera.koplugin/lib/libquickjs.so`（436464 B，strip 后，sha256 `1055dfcb…70b7d6041`，不入 git）。北京实例 `lhins-ni6p5t1q` + koxtoolchain kindle5（2026.08，资源名 `kindle5.tar.zst`）+ quickjs-ng v0.17.0 MinSizeRel。readelf 实测：ARM EABI5、e_flags `0x05000200`（EF_ARM_ABI_FLOAT_SOFT，无 hardfp 位）、GLIBC 仅 2.4（≤2.12）、`JS_*` 导出齐全；本地 sha256 链 + ELF 复核 PASS，仓库回归 ALL GREEN（109/0、15/15、hold clean、vendor 不变）。传输 = 实例临时端口 + 防火墙临时规则 + 本地 PowerShell 直拉（详见 handoff D2 记录）。顺带修复 build-quickjs.sh：quickjs-ng CMake 产物名实为 `libqjs.so.0.17.0`，原脚本检查 `libquickjs.so` 必失败。
