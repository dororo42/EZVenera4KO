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
2. **ADR-002：vendor init.js 完整性**——`vendored/init.js` 锁 sha256，修改须同步 `.sha256` 与版权头。
3. **ADR-003：插件自带 HTTP 代理层**——不依赖 `NetworkMgr:setHTTPProxy`，后者只影响 `socket.http`，HTTPS 不走代理。
4. **ADR-004：Rust 不进入关键路径**——crate 保留作后备，不纳入 M2 计划。
5. **扫码远程输入（remoteinput）已删除**（用户决策 2026-09-22，取代原 ADR-007 拆仓计划）——源码/测试/文档已从本仓移除，不得恢复。
6. **凭据安全**——SSH/云服务凭据一律走 MCP/OAuth 或用户本地环境，禁止入仓、入文档、入脚本。

## 当前 Handoff

- **位置**：`handoffs/2026-09-23-0905-ezvenera-android-engine-apk/`（HANDOFF.md + RESUME_PROMPT.md，整合版；前驱链在 `handoffs/2026-09-21-2103-ezv-dual-device-deploy/` 的 6 份 ADDENDUM）
- **状态**：安卓引擎随 APK 分发落地（T-S3）：零 patchelf 构建 + APK 注入重签安装，dlopen/init/eval 全链稳定，用户真机实测零崩溃（2026-09-23）。双历史根因已修（patchelf verneed 损坏、pump 回调竞态→no-op）。promise 型源数据（分类/搜索）待 S2 主循环泵。
- **2026-09-24 之后已落地（真机验证，尚未 git 提交）**：搜索闭环可用、章节列表/前后章切换、整章下载 + 下载与缓存管理、收藏夹 + 阅读历史、已装源参数配置、自定义漫画源四条路径（URL 直装 / 自定义 index.json / 本地文件 / 索引浏览）、安卓 ANR 消除（联网一律走 `scheduleIn` 节拍）、SimpleUI 对接（顶层 `callback` + 3 个 QA 描述符）、KOReader 设置自动落盘（修「键盘布局每次重开都要重设」）。闸门：270 单测 / 语法 17 / no-hold / vendored 全绿。
- **发布状态**：用户要求把仓库公开到 `github.com/dororo42/`（含 LICENSE 与详细安装 README）。README、`scripts/android/*`（脱敏后的安卓引擎构建 + APK 注入/重签配方）已入工作树；`handoffs/` 的脱敏暂存树在仓库外生成（内网 IP、免密 SSH、sudo 口令、设备序列号需替换）。**聊天里贴过的 GitHub PAT 必须先由用户吊销/轮换**，确认仓库名与可见性后再推。
- **下一步**：公开推送 → 真机回归（引擎 Release 资产可选）→ 清理 `selftest.lua` 与启动标志文件诊断件（任务 #17/#24 遗留）→ git 分批提交；Kindle 4 冻结（恢复时按零 patchelf 配方重编）
