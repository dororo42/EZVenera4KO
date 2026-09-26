# EZVenera for KOReader — 项目规则与接手指南

> 本项目使用 [agent-handoff-delivery](https://github.com/dororo42/agent-handoff-delivery) 标准。
> 最新交接文档位于 `handoffs/` 目录，按时间戳排序取最新一份。

## 项目概览

在 KOReader（LuaJIT）中运行 Venera/EZVenera JS 漫画源插件的移植层。
**当前开发优先级：安卓平板（触屏）；Kindle 4 暂缓**（用户决策 2026-09-22）。

- 语言/栈：Lua（KOReader 插件）+ quickjs-ng（JS 引擎）+ Python（测试/CI）
- 架构决策见 `changes/ezvenera-koreader-port/design.md`（7 项 ADR）
- 需求见 `specs/requirements.md`
- 任务分解见 `changes/ezvenera-koreader-port/tasks.md`

## 关键红线（不得违反）

1. **ADR-005：禁止 hold 依赖**——Kindle 4 所有配置入口仅用普通菜单项（`callback`）。本仓库有 CI 检查 `scripts/check_no_hold.py`（扫描 `src/koreader-plugin/` 下**全部** `.koplugin`）。
2. **ADR-002：vendor init.js 完整性**——`vendored/init.js` 锁 sha256，修改须同步 `.sha256` 与版权头。该文件由 `.gitattributes` 钉成 **LF**（含 `.sha256` 本身）：哈希签的是字节，`core.autocrlf` 在 add 时压掉 CRLF 会让 CI 检出的 blob 与 `.sha256` 记录值差 1519 字节（2026-09-24 CI 就因此红过一次）。
3. **ADR-003：插件自带 HTTP 代理层**——不依赖 `NetworkMgr:setHTTPProxy`，后者只影响 `socket.http`，HTTPS 不走代理。
4. **ADR-004：Rust 不进入关键路径**——crate 保留作后备，不纳入 M2 计划。
5. **扫码远程输入（remoteinput）已删除**（用户决策 2026-09-22，取代原 ADR-007 拆仓计划）——源码/测试/文档已从本仓移除，不得恢复。
6. **凭据安全**——SSH/云服务凭据一律走 MCP/OAuth 或用户本地环境，禁止入仓、入文档、入脚本。

## 当前 Handoff

- **位置**：`handoffs/2026-09-23-0905-ezvenera-android-engine-apk/`（HANDOFF.md + RESUME_PROMPT.md，整合版；前驱链在 `handoffs/2026-09-21-2103-ezv-dual-device-deploy/` 的 6 份 ADDENDUM）
- **状态**：安卓引擎随 APK 分发落地（T-S3）：零 patchelf 构建 + APK 注入重签安装，dlopen/init/eval 全链稳定，用户真机实测零崩溃（2026-09-23）。双历史根因已修（patchelf verneed 损坏、pump 回调竞态→no-op）。promise 型源数据（分类/搜索）待 S2 主循环泵。
- **2026-09-24 之后已落地（真机验证，2026-09-26 已分批提交）**：搜索闭环可用、章节列表/前后章切换、整章下载 + 下载与缓存管理、收藏夹 + 阅读历史、已装源参数配置、自定义漫画源四条路径（URL 直装 / 自定义 index.json / 本地文件 / 索引浏览）、导入版本护栏 + `sha256` 真值 + 重名可分辨 + 回退到旧版、安卓 ANR 消除（联网一律走 `scheduleIn` 节拍）、SimpleUI 对接（顶层 `callback` + 3 个 QA 描述符）、KOReader 设置自动落盘（修「键盘布局每次重开都要重设」）。
- **v2.0.0 重制包真机回归（2026-09-26）**：13 源全链路通过（源列表/主页/分类/详情/章节/阅读/前后章/下载/缓存/离线/收藏/历史/搜索/引擎状态）。修掉两个真缺陷：① URL 型 `mandatory` 过宽触发 `makeLine (width must be strictly positive)` 崩溃 → `browser.lua` 的 `shortMandatory()` 统一裁剪；② URL 型 epId 章节乱序 → 按标题话号排序。闸门：339 单测 / 语法 16 / no-hold / vendored 全绿。
- **阅读翻页修复（2026-09-26，真机确认）**：报告里的「阅读崩溃」不是崩溃（无 tombstone / crash.log / dropbox 记录），真缺陷是 `browser.lua` 的图片路由**一次代理超时就把主机永久钉死直连**——而 xmanhua 图床直连被 RST（主机侧 `curl` 对照：直连 reset、走代理 403），于是翻页退化成不可恢复的灰底占位页。改为「探测—确认」：超时只标记可疑 → 下一拍直连探测，探测也失败就收回标记回到代理，只有「代理失败 + 直连成功」才钉死直连。日志侧印证 `pn 1→8` 连续出图、缓存 299→3525 KB，`proxy broken / 钉死直连 / image fetch failed` 0 条。闸门：340 单测 / 语法 16 / no-hold / vendored 全绿。
- **阅读器一批改动（2026-09-26，源仓 `b2d1855`）**：① 底部**可拉页码条**（上游 `HorizontalScrollBar` + 「第 N / M 页」文本；拖动途中只改显示、按下/抬起才跳页，目标页无缓存交给预取节拍，绝不在手势回调里同步取图）——真机已确认可见可用；② **另存本页**：长按（按住不动抬起）接管上游 `ImageViewer:onHoldRelease` 的「墨水屏全刷」那一支改成存图，带位移的一支照常平移缩放；导航条同时加第四个普通 `callback` 键【存图】（ADR-005）。落点 `<dataDir>/ezvenera/saved/<书名>/<章节>_pNNN.<后缀>`，存的是图床原图字节不是截屏；书名用逐 UTF-8 码点清洗（`%w` 只认 ASCII，套 `safeId` 会把中文压成下划线；截断必须停在码点边界）。**这一项已真机点验通过（2026-09-26，用户回报 ok）**：长按存图、【存图】键、页码条拖动跳页三项在真机确认可用。③ 清掉 SIGSEGV 排查期的 RSS 探针（每 2s 一条 logcat）。④ 修掉真机缺陷：`TextWidget` 不传 `face` → `getSize()` 里 `Font:getAdjustedFace(nil)` 报错 → 整页码条被自己的 `pcall` 静默吞掉（表现为「进度条不见了」）；现已显式取 `pgfont` 并让降级 `logger.warn` 留痕，桩里补了 `face` 必填断言钉成回归。闸门：361 单测 / 语法 16 / no-hold / vendored 全绿。
- **提交前脱敏（2026-09-26，脚本在仓库外 `ezv_scratch/sanitize_repo_md.py`）**：`*.md` 里的本机绝对路径、局域网主机号/端口、ssh 别名、keystore 与 sudo 口令提法全部换成占位说法（残留断言为 0）；`tools/.venv/`、`scripts/__pycache__/` 取消跟踪。
- **凭据暴露面（2026-09-26 公开侧已重写收口）**：涉及两行字面量——签名 keystore 口令、构建机 sudo 口令提法。① **本机**：工作树与 `d5bbf09`（提交前脱敏）之后的提交干净；未脱敏的 r3 副本分支 `public-main` 已删，三枚未脱敏快照（r1 `6b0085a` / r2 `a248a4f` / r3 副本 `b5b7c35`）已随 `git gc --prune=now` 物理回收——它们原本被 `.git/logs/HEAD` 条目的 **old value** 钉住（`fsck` 报 dangling 却仍能 `cat-file -e`），先就地改写那三条 old value 再 gc 才真丢；**别整条 `reflog expire`**，那会连 amend 前像等恢复锚点一起丢掉。本仓 `main` 的 23 条提交里 11 条早期提交（`4cb4cb5`…`5642a62`）树内仍含字面量：本仓无 remote，重写只会作废 AGENTS.md/handoff 引用的全部 sha，**判定不做**，轮换凭据即闭环。② **公开仓（用户批准后已完成）**：四条快照用纯 plumbing 逐提交重放（`read-tree` + 临时 `GIT_INDEX_FILE` + `hash-object -w --stdin` + `update-index --cacheinfo` + `write-tree` + `commit-tree -p`，只替换命中的 `*.md` blob，消息/作者/提交者/两个日期按原值经 `GIT_*_{NAME,EMAIL,DATE}` 复刻），**新 tip 的树 sha 与重写前完全相同 → 已发布内容零变化**，`--force-with-lease` 推送。**同一轮还抓到漏网的一处**：tag `v0.2.0` 指向链外孤儿提交 `03e17fc`，其 `handoffs/2026-09-23-*` 两份文档仍含 keystore 口令——同样重放为 `ac257dd` 并移动 tag；Release 与其资产按 **tag 名**挂载，只移动不删除故资产完好（实测下载 206 正常）。③ **剩余只能用户做的**：旧 sha（`91a8d12`/`b39e89c`/`d2da9f3`/`f1c434c`/`03e17fc`）已无任何 ref 指向，但 GitHub 服务端仍缓存，彻底抹除需开 Support 工单做对象 GC 并确认有无 fork；口令一旦公开即视为已泄露，**无论历史抹没抹净都要**轮换 keystore（签名变更 → 平板须 `adb uninstall` 重装，`/sdcard/koreader` 数据保留）与构建机 sudo 口令。④ **口径教训**：`git grep <pat> <branch>` 只扫 tip 树，断言「已清干净」必须逐提交重扫（`for c in $(git rev-list …); do git grep -q … $c; done`）或 `git log -S`；脱敏规则必须覆盖 `（pass: <口令>）` / `/pass <口令>` 这类写法——`make_pub_stage.py` 原先只认 `口令=<REDACTED> / `password=<REDACTED> / `sshpass -p`，r3 正是从这里漏出去的。
- **发布状态（2026-09-26：r7 已推送；同日早前完成 r6 与公开历史重写）**：公开仓 **https://github.com/dororo42/EZVenera4KO**（GPL-3.0，`private=False`，默认分支 `main`）。发布走**仓库外的脱敏暂存树**（`ezv_scratch/make_pub_stage.py`：只重写 `*.md`，其余字节原样复制并断言 sha256 相等；**跑之前必须清空暂存树**，脚本的删除步骤是空操作），历史与本地工作树都不外泄；引擎以 Release 资产 `ezvenera-engine-android-arm64.zip` 分发（当前 `v0.2.0`，392371 字节），不重分发 KOReader APK。**当前公开 ref**：`main` = `229d1f7`（r7，源仓 `b2d1855` + `8521251`：底部可拉页码条 + 长按/【存图】另存本页原图 + 清 RSS 探针刷屏）← `5c0a6d3`（r6，源仓 `d611648`：图片路由「探测—确认」修复 + 回归单测 + AGENTS.md）← `9c018d8`（r5，只对齐文档一段）← `d550ebc`（r4：删诊断件 + `shortMandatory` + 章节按话号排序 + 导入版本护栏 + 清掉误公开的 `__pycache__`/`pyvenv.cfg`）← `d6f34b1`（r3）；tag `v0.2.0` = `ac257dd`（原 `03e17fc`，2026-09-26 历史重写后）。重写产生的映射 `5c0a6d3`/`9c018d8`/`d550ebc`/`d6f34b1`/`ac257dd` 之前那批旧 sha（`91a8d12`/`b39e89c`/`d2da9f3`/`f1c434c`/`03e17fc`）已作废，只在 GitHub 缓存里短暂残留。r7 为**快进推送**（`commit-tree` 挂 `5c0a6d3`，无强推），暂存树与源仓 92 文件逐 blob 对拍：差异只允许落在 6 个被脱敏改写的 `*.md`，`vendored/init.js` + `.sha256` blob 与源仓同 sha。**公开仓 `AGENTS.md` 的 ref 记录天然落后一次**（发布树里不能包含"我已发布 r7"这句话本身），以本条为准。快照平时走 `commit-tree` 挂远端 HEAD 的快进推送；本轮清历史是**唯一一次**不改写例外（经用户批准）。重写脚本：`ezv_scratch/scrub_tag_commit.py`（链外单提交重放，同一套规则）。CI `test` / `engine-build-dryrun` 在新 tip 上实测双绿。
- **下一步**：只剩用户侧三件——① 吊销聊天里贴过的 PAT（**已用于 r4/r5/r6 三次推送，立即作废**；重写这一轮起改用本地已配置的凭据助手，命令行里不再出现明文 token）；② 开 GitHub Support 工单对 `EZVenera4KO` 做对象 GC，并确认有无 fork（`main` 旧链 `91a8d12`… 与 tag 旧指 `03e17fc` 已无 ref 指向，但服务端仍缓存，`github.com/dororo42/EZVenera4KO/commit/<旧sha>` 在 GC 前仍可打开）；③ 轮换签名 keystore 与构建机 sudo 口令（**这步跟历史抹除无关，必须做**；keystore 换签名 → 平板须 `adb uninstall` 重装，`/sdcard/koreader` 数据保留）。`categoryComics.optionLoader` 动态筛选**暂不补**（用户决策 2026-09-26）；Kindle 4 冻结（恢复时按零 patchelf 配方重编）
- **诊断件已清除（2026-09-25）**：`selftest.lua`、启动标志文件 `/sdcard/koreader/ezv_selftest` 的读取钩子、菜单「自检(排查用)」全部删除
