# 提案：EZVenera for KOReader（changes/ezvenera-koreader-port）

## 为什么

用户诉求（原始输入，2026-09-20）：
1. 分析 WEP-56/EZVenera（Flutter 漫画阅读器，插件驱动，兼容 Venera JS 插件生态）
2. 评估移植为 KOReader 插件的可行性
3. 评估 Rust 优化空间
4. 适配 e-ink / Kindle 4 的硬件与操作（含"KO 网页代理需长按开启，K4 不支持长按"问题）
5. 插件内代理设置（局域网代理；具体地址不入仓，审查 L5）

## G0 结论摘要（详见 reports/，不入库）

- **移植可行**。EZVenera 插件契约 = 单 JS 文件 + sendMessage 宿主 API，JS 侧标准库 `init.js` 1520 行，可直接 vendor（GPL-3.0 兼容）。宿主 API 面已 100% 摸清（含全部 quirk）。
- **架构**：KOReader Lua 插件 + quickjs-ng（FFI，koxtoolchain softfp 工具链交叉编译）+ Lua 实现 Venera 宿主 API。
- **Rust 当前不建**：KOReader 已捆绑 OpenSSL（AES）与 mupdf/libjpeg-turbo/libwebp 图像栈；Rust 的动机已被覆盖，保留 musleabi 构建配方作 P2 后备。
- **长按问题**：KOReader ≥2024.07 在 K4 上支持 ScreenKB+Press=长按，但①不可发现②原生代理仅对 HTTP 生效（ssl.https/turbo/httpasync 全不过代理）→ 插件提供纯普通菜单的代理设置并对 http/https 同时生效，是正解。
- **Kindle 4 约束**：256MB RAM、800MHz 单核、8bpp 无 HW 抖动、D-pad 输入、softfp+glibc2.12 工具链、包体要小。

## 影响 / 交付物

- 新增 `src/koreader-plugin/ezvenera.koplugin/`（KOReader 插件）
- 新增 `scripts/`（quickjs 交叉构建、MRPI 打包、测试运行器）
- 新增 `rust/`（仅配方与骨架，不在关键路径）
- 新增 `specs/requirements.md`（需求与验收）
- 新增 `handoffs/`（跨 agent 交接套件，可提交）
- `reports/` 为研究档案，**不提交**（用户要求）

## 风险

1. HTML 解析/CSS 选择器对等（最大件，M2 专门处理）
2. quickjs 与老工具链的 C11 兼容（Spike S2 前置验证）
3. LuaSec CONNECT 隧道行为需真机确认（备选：自写 CONNECT 实现）
4. modifyImage 像素级一致性（P2，快照回归前置）
