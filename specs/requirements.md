# EZVenera for KOReader — 需求规格（v1.1）

> 状态：G1 PASSED（2026-09-20）；**v1.1（2026-09-24）：设备优先级修订——安卓平板优先，Kindle 4 冻结（用户决策 2026-09-22，与 AGENTS.md 一致）**
> 溯源链：REQ → AC → DESIGN/ADR → TASK → CODE → TEST → VERIFY
> 证据分级：需求本身为用户输入与 G0 研究的规范化；每条 AC 必须可观测。

## 0. 产品定义

**EZVenera for KOReader**（`ezvenera.koplugin`）：在 KOReader（Lua）内运行 Venera/EZVenera JS 漫画源插件的移植层。

**设备优先级（2026-09-24 修订）**：
- **当前开发与验收目标：安卓平板（触屏，arm64）**——真机验收、引擎分发（APK 注入）均以此为准；
- **Kindle 4（非触屏）：冻结的支持目标**——代码路径保留、CI 闸门保持全绿，真机验收项挂起至设备解冻（标注"冻结-恢复时验收"）；
- 通用约束（无长按红线 ADR-005、无 Amazon 服务假设）在两类设备上均有效。

范围声明：
- 兼容对象是 EZVenera 的插件运行时契约（`class X extends ComicSource` + sendMessage 宿主 API），不是 Flutter 应用本身。
- 上游刻意裁剪的能力（UI.*、评论/点赞、explore/favorites、WebSocket）继续裁剪。
- 初始交付不包含 Rust 原生库（见 ADR-004），但保留构建配方。

## 1. 功能需求

### R1 插件框架
| REQ | 内容 | 优先级 |
|---|---|---|
| R1.1 | 以 `.koplugin` 目录安装于 KOReader 用户插件目录，KOReader 重启后可加载 | P0 |
| R1.2 | 注册主菜单项（Tools/EZVenera 漫画），包含：浏览源、管理插件源、网络代理、状态 | P0 |
| R1.3 | 自有持久化设置（`settings/ezvenera.lua`），写盘 flush 可恢复 | P0 |
| R1.4 | 缺少 JS 引擎库时优雅降级：菜单显示状态"引擎未安装"，其余功能不崩溃 | P0 |

**AC**
- AC1.1 把插件目录拷入 `<koreader>/plugins/` 后，菜单出现"EZVenera 漫画"（真机/模拟器，人工核验）。
- AC1.2 修改任意设置并退出 KOReader 再进入，设置保持（真机人工核验 + 本地单测覆盖 LuaSettings 适配层）。
- AC1.3 无 `lib/libquickjs.so` 时：状态页显示"JS 引擎未安装"，浏览/搜索入口提示原因，无 Lua error（可由桩测试覆盖部分）。

### R2 代理（用户核心痛点）
| REQ | 内容 | 优先级 |
|---|---|---|
| R2.1 | 代理配置**全部通过普通菜单项**完成（开关/编辑/恢复默认/测试），不依赖长按（hold_input） | P0 |
| R2.2 | 代理地址可编辑、可恢复默认；**默认值为空**（2026-09-20 修订：原预置内网 IP 不再入仓，真机首配——审查 L5） | P0 |
| R2.3 | 代理应用于插件自身全部 HTTP(S) 请求：HTTP 走 socket.http 代理，HTTPS 经 CONNECT 隧道 | P0 |
| R2.4 | 可选：同步应用到 KOReader 全局 `socket.http.PROXY`（开关，默认关，避免干扰 OPDS 等其它功能） | P1 |
| R2.5 | 提供"测试代理"菜单项：经代理请求一个探测 URL，报告成功/失败与耗时 | P0 |
| R2.6 | 代理地址格式校验（scheme://host:port），非法输入拒绝保存并提示 | P0 |

**AC**
- AC2.1 【冻结-恢复时验收（Kindle 4）】仅用 D-pad+Press 可完成：开启代理→修改地址→保存→测试通过，全程无长按操作。**当前等效验收（安卓平板）**：触屏+可选键盘完成同一流程，且代理子菜单结构经无 hold 断言（check_no_hold.py）。
- AC2.2 首次安装未配置时，代理地址默认值为空串（单测断言默认值为空）；首次启用时菜单引导『编辑代理地址』输入。
- AC2.3 单测：代理开关关闭时请求直连（fake socket 断言无 proxy 参数）；开启时 http 请求带 proxy；https 请求走 CONNECT 封装路径。
- AC2.4 单测：`foo`、`203.0.113.10`（缺 scheme）、`http://`（缺 host:port）被拒绝；`http://203.0.113.10:16492`（RFC 5737 文档地址）通过。
- AC2.5 真机（当前=安卓平板；Kindle 4 版冻结）：代理开启后能通过代理访问外网源并加载一页漫画（人工验收）。

### R3 漫画源运行时（Venera 兼容层）
| REQ | 内容 | 优先级 |
|---|---|---|
| R3.1 | 加载 `sources/*.js`（Venera/EZVenera 插件文件），解析失败静默跳过并记录 | P0 |
| R3.2 | 实现 sendMessage 宿主 API（Lua 侧 handler）：`http`、`convert`（§3 清单）、`load/save/delete_data`、`load_setting`、`isLogged`、`cookie`、`log`、`delay`、`random`、`uuid`、`getLocale`、`getPlatform`、`set/getClipboard`、`html`、`image`、`compute` | P0（http/convert/data/settings 先行）；`html` P1；`image`/`compute` P2 |
| R3.3 | `convert` 必须与 pointycastle 行为一致：AES-ECB/CBC/CFB8/OFB **无填充**、raw 摘要（md5/sha1/sha256/sha512）、HMAC（含 hexString 变体）、base64、UTF-8；GBK 解码为 P2 | P0 |
| R3.4 | 漫画源管理：从索引浏览/安装/更新/删除源文件。**默认索引** = `https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/index.json`（WEP-56/EZvenera-config 仓库，可配置 URL；索引条目 schema = `[{name, fileName, key, version, description?}]`，下载地址 = 索引基址 + `fileName`，提供 jsdelivr CDN 备选以改善直连可达性）。**本地源**：用户在指定目录（`<data>/ezvenera/index/`）放置的 `*.json` 索引文件参与合并（同 `key` 时本地条目优先），支持本地 `.js` 直接安装 | P1 |
| R3.5 | 浏览流程：源列表→搜索/分类→结果列表→详情→章节→图片页序列 | P1 |
| R3.6 | 图片管线：onImageLoad→headers/method 处理→onResponse→modifyImage（P2）→下载缓存→显示 | P1（modifyImage P2） |

**AC**
- AC3.1 单测：用固定样例 JS（模板级最小 ComicSource）经 quickjs 引擎解析出 name/key/version（需引擎，S2 后）。
- AC3.2 单测：AES-128-ECB/CBC NIST 测试向量与 pointycastle 无填充语义一致（16 字节块输入）。
- AC3.3 单测：md5("abc")、sha256 NIST 向量；base64 round-trip；hexEncode。
- AC3.4 单测：Network 响应模型 `{status, headers(值逗号连接), body}` 形状与错误不抛出语义。
- AC3.5 真机：安装一个纯 JSON API 型源（如 copy_manga）完成 搜索→详情→打开第一章 链路（人工验收，P1 后）。

### R4 阅读与显示
| REQ | 内容 | 优先级 |
|---|---|---|
| R4.1 | 页图用 ImageViewer 图像列表模式 + 惰性下载（opdspse 蓝图）；翻页：触屏滑动（安卓）+ D-pad/PgFwd/PgBack（Kindle 4 冻结路径） | P1 |
| R4.2 | 显示前降采样/裁剪到面板宽（≤800px 宽），解码内存上限保护（256MB 设备） | P0（阅读路径一启用即生效） |
| R4.3 | 翻页后全刷（full, dithered）清残影；菜单内不使用动画 | P1 |
| R4.4 | 下载超时与失败提示（socketutil 超时框架），失败页可重试 | P1 |

**AC**
- AC4.1 打开一章：内存峰值 < 60MB（真机 `cat /proc/meminfo` 或 KOReader RAM 指示器观测）。
- AC4.2 翻页后屏幕无可见残影（真机人工）；翻页动作本身无动画残留。
- AC4.3 断网时打开页面：显示失败提示而非卡死（可本地模拟超时单测 netclient 超时分支）。

### R5 非触屏 / e-ink 操作适配（Kindle 4 冻结；红线在安卓上同样生效）
| REQ | 内容 | 优先级 |
|---|---|---|
| R5.1 | 全部菜单/对话框仅用普通菜单项可达可操作；不依赖 hold/长按路径（ADR-005；触屏设备同样遵守，保键盘/无触屏兼容） | P0 |
| R5.2 | 文本输入双路径：触屏键盘（安卓）+ 屏幕虚拟键盘/设置文件指引（Kindle 4，冻结） | P1 |
| R5.3 | 不假设 Amazon 服务可用；插件更新经用户显式触发 | P1 |

**AC**
- AC5.1 【冻结-恢复时验收（Kindle 4）】走查清单（菜单→代理→浏览→阅读→返回）全部动作仅用 Up/Down/Left/Right/Press/Back/Menu 完成（真机人工）。**当前等效验收（安卓）**：同一走查清单全触屏完成且无 hold 依赖。
- AC5.2 grep 检查插件代码无 `hold_input`/`hold_callback` 依赖关键路径（脚本化检查，随 CI/测试跑）——**冻结期间照常生效**。

### R6 JS 引擎
| REQ | 内容 | 优先级 |
|---|---|---|
| R6.1 | quickjs-ng 交叉编译为 `lib/libquickjs.so`：**当前目标 = Android arm64（NDK，随 APK 分发，零 patchelf 配方）**；`arm-kindle5-linux-gnueabi`（softfp/glibc2.12）目标冻结，恢复时按冻结配方重编；构建脚本入仓 | P0 |
| R6.2 | LuaJIT FFI 绑定：runtime/context 创建、eval、promise 泵（UIManager 调度）、sendMessage 桥 | P0 |
| R6.3 | 运行时内存限制（JS_SetMemoryLimit ≤ 8MB/运行时）与 OOM 时回收 | P1 |
| R6.4 | x86_64 构建目标用于开发/CI 测试 | P1 |

**AC**
- AC6.1 构建脚本在 Linux/WSL 产出 `.so`，file 输出为 ARM soft-float（`EABI5, hard-float 标志不存在`）（S2 验证）。
- AC6.2 冒烟脚本：eval `class+async/await+Promise` 用例返回正确值；Lua→C→JS→Lua 回调往返不崩（S2）。
- AC6.3 x86_64 下同一套绑定通过单测（宿主开发路径）。

### R7 安全与合规
| REQ | 内容 | 优先级 |
|---|---|---|
| R7.1 | 不记录/不持久化任何凭证明文（账号密码由插件自身决定存储位置——沿用 Venera data 机制，属插件行为） | P0 |
| R7.2 | 安装/更新源文件需用户确认；不自动执行 | P0 |
| R7.3 | 项目以 GPL-3.0 发布，vendored init.js 保留版权与来源声明 | P0 |

## 2. 非需求（明确不做）

- Flutter/EZVenera 应用 UI 的复刻；评论/点赞/打赏类 API；WebSocket；UPnP/发现；触屏手势专属交互。
- Rust 原生库的初始集成（保留配方与骨架，见 ADR-004）。
- 追更/推送通知。

## 3. 验收机制总表

| 层 | 机制 |
|---|---|
| 单测（宿主可跑） | Python+lupa 驱动 LuaJIT：proxy 校验、netclient 代理选择、convert 向量（注入 fake/openssl 后端）、cookies、storage、菜单结构无 hold 断言 |
| 冒烟（S2 后） | x86_64 quickjs + vendored init.js + 最小样例插件 |
| 真机清单 | **当前（安卓平板）**：AC1.1/AC2.5/AC3.5/AC4.1/AC4.2 人工验收（adb/HTTP 调试）。**冻结（Kindle 4）**：AC2.1/AC5.1 挂起，恢复时按 §0 冻结口径核销 |
| 静态检查 | Lua 语法检查（luacheck 若可得 / luac -p）、hold 依赖 grep、密钥扫描 |
