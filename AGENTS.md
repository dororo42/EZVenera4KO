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
- **提交前脱敏（2026-09-26，脚本在仓库外 `ezv_scratch/sanitize_repo_md.py`）**：`*.md` 里的本机绝对路径、局域网主机号/端口、ssh 别名、keystore 与 sudo 口令提法全部换成占位说法（残留断言为 0）；`tools/.venv/`、`scripts/__pycache__/` 取消跟踪。
- **凭据暴露面（2026-09-26 定案，待用户处置）**：脱敏后的工作树/新提交是干净的，但**公开仓历史里的 r3 快照 `f1c434c` 仍含两处口令字面量**（签名 keystore 口令、构建机 sudo 口令提法），本地仓历史与本地分支 `public-main`（未脱敏的 r3 副本）同样含。口令一旦公开即视为已泄露：① keystore 重建/轮换（后果要预告：签名变更 → 平板须 `adb uninstall` 重装，`/sdcard/koreader` 数据保留）；② 构建机 sudo 口令改密；③ 若要清掉公开历史里的 blob，只能重写 `main` 并强推，且需 GitHub Support 才能彻底 GC——属破坏性共享操作，需用户点头才做。
- **发布状态（r5 已重发 2026-09-26）**：公开仓 **https://github.com/dororo42/EZVenera4KO**（GPL-3.0，`private=False`，默认分支 `main`）。发布走**仓库外的脱敏暂存树**（`ezv_scratch/make_pub_stage.py`：只重写 `*.md`，其余字节原样复制并断言 sha256 相等），历史与本地工作树都不外泄；引擎以 Release 资产 `ezvenera-engine-android-arm64.zip` 分发（当前 `v0.2.0`，392371 字节），不重分发 KOReader APK。公开 `main` = `b39e89c`（r5），前一站 `d2da9f3`（r4：删诊断件 + `shortMandatory` + 章节按话号排序 + 导入版本护栏 + 清掉误公开的 `__pycache__`/`pyvenv.cfg`），r5 只对齐 AGENTS.md 一段；CI `test` / `engine-build-dryrun` 双绿。**注意：公开 `main` 停在阅读修复之前**，重发 r6（含图片路由修复）待用户点头。
- **下一步**：吊销聊天里贴过的 PAT（用户侧，**已用于 r4/r5 两次推送，立即作废**）；上面「凭据暴露面」三项处置（用户侧）；`categoryComics.optionLoader` 动态筛选**暂不补**（用户决策 2026-09-26）；Kindle 4 冻结（恢复时按零 patchelf 配方重编）
- **诊断件已清除（2026-09-25）**：`selftest.lua`、启动标志文件 `/sdcard/koreader/ezv_selftest` 的读取钩子、菜单「自检(排查用)」全部删除
