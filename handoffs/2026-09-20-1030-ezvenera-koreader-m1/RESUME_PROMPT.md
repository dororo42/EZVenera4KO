# EZVenera for KOReader — Resume Prompt

你接手一个项目：**EZVenera for KOReader**（在 KOReader LuaJIT 中运行 Venera/EZVenera JS 漫画源插件的移植层，首发 Kindle 4 非触屏）。

## 项目状态

M1 已完成：插件骨架（`src/koreader-plugin/ezvenera.koplugin/`）+ 网络代理设置（纯菜单无长按）+ JS 引擎桩 + 75 项单测 + CI。

## 你的第一个动作

1. **读项目规则**：`AGENTS.md`（红线：禁止 hold 依赖、vendor 完整性、Rust 不关键）
2. **读交接文档**：`handoffs/2026-09-20-1030-ezvenera-koreader-m1/HANDOFF.md`（当前状态、架构决策、已知坑）
3. **读设计/ADR**：`changes/ezvenera-koreader-port/design.md`（6 项 ADR 必读）
4. **读需求**：`specs/requirements.md`
5. **读任务分解**：`changes/ezvenera-koreader-port/tasks.md`
6. **跑检查**：`make check`（语法 → 测试 → 无hold → vendor 校验）

## 立即下一步

1. **Spike S1** — 在 KOReader 真机上验证 `convert.lua` 的 OpenSSL EVP cdef 扩展可工作（AES-128-CBC NIST 向量）。
2. **Spike S2** — `scripts/fetch-quickjs.sh` + koxtoolchain kindle5 编译 `lib/libquickjs.so`，真机验证 FFI 回调。
3. **M2** — 实现 htmlparse/sources/browser/reader。

## 关键文件索引

- 插件源码：`src/koreader-plugin/ezvenera.koplugin/main.lua`（入口）
- 代理配置：`.../proxyconf.lua`（纯菜单全部 callback，`check_no_hold.py` 约束）
- 消息桥：`.../runtime/bridge.lua`（对齐 `vendored/init.js` 精确字段名）
- Crypto：`.../runtime/convert.lua`（OpenSSL FFI 回退纯 Lua）
- Cookie：`.../runtime/cookies.lua`（域匹配/路径/Secure/持久 JSON）
- JS 引擎：`.../runtime/jshost.lua`（quickjs-ng FFI，S2 冒烟后可用）
- 测试：`tests/`（7 文件 75 项，lupa LuaJIT 2.1）
- 构建脚本：`scripts/build-quickjs.sh`（kindle/x86_64）
- Rust 后备：`rust/ezvjs-bridge/`（ADR-004，cargo check 通过）

## 禁止操作

- 禁止把 `reports/` 提交进 git（用户要求研究档案不入仓）
- 禁止在配置路径使用 `hold_input`/`hold_callback`（Kirino ALE 4 红线）
- 禁止提交 `.env`、token、对话记录
