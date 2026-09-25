# EZVenera for KOReader — Resume Prompt（第二份）

你接手一个项目：**EZVenera for KOReader**（在 KOReader LuaJIT 中运行 Venera/EZVenera JS 漫画源插件的移植层，首发 Kindle 4 非触屏，同时适配安卓平板触屏）。

## 项目状态

- M1 完成 + 20/20 审查发现全部落实；终态：语法 15/15、单测 109/0、hold 红线 clean（全插件）、vendor sha256 不变。
- **remoteinput.koplugin（扫码远程输入）已作为独立插件交付**：纯 Lua QR 编码器（zxing-cpp 真解码 7/7）+ 局域网临时 HTTP 服务（一次性 token）+ 弱依赖接入 EZVenera 输入框。
- 关键缺口：`lib/libquickjs.so` 未编译（构建产物不入仓）——插件能装、配置能用，但 JS 漫画源跑不了。

## 用户既定决策（必须遵守）

1. 两个插件**分别建 GitHub 仓库，暂不一起打包**（package-mrpi.sh 勿改）；
2. libquickjs.so 优先在 Tencent Cloud Lighthouse 交叉编译（koxtoolchain 预编译工具链路线），Panther X2 已评估为不推荐（aarch64/x86_64 工具链不匹配）；
3. 双设备（安卓平板 + Kindle 4）SSH 部署测试，**等用户通知**再执行；
4. 后续有其他团队审查接手——所有决策以 design.md ADR + tasks.md + handoffs/ 为准。

## 你的第一个动作

1. 读 `AGENTS.md`（红线）→ `handoffs/2026-09-20-1749-ezvenera-remoteinput-split/HANDOFF.md`（**本份为最新**，含编译配方/拆仓清单/真机冒烟顺序）→ 前序 `handoffs/2026-09-20-1030-ezvenera-koreader-m1/HANDOFF.md`（架构决策与已知坑仍有效）→ `changes/ezvenera-koreader-port/design.md`（7 项 ADR）→ `tasks.md`
2. 跑检查：`make check`（语法→测试→无hold→vendor）

## 立即下一步

1. **GitHub 拆仓**：remoteinput 独立仓库（随迁 test_qrcode/test_server/test_api/stubs_remote）；ezvenera 仓保持现状。
2. **Lighthouse 编译** `lib/libquickjs.so`（HANDOFF.md 路线 A 配方 + readelf 验证三步：ARM/EABI、无 Tag_ABI_VFP_args、GLIBC ≤2.12）。
3. **等通知** → 双设备部署冒烟（先 remoteinput 独立入口，后 S1/S2）。
4. 安卓平板路径需单独 spike（bionic/arm64 NDK .so + dlopen W^X 验证，Kindle 产物不可复用）。

## 禁止操作

- 密钥/凭据一律不入仓不入文档（走 MCP/OAuth）
- `reports/` 不入仓；`hold_input/hold_callback` 禁用（ADR-005）
- 修改 `vendored/init.js` 须同步 `.sha256`（ADR-002）
- 改 qrcode.lua 前先读 HANDOFF.md「三个历史坑」，回归锚点 `tools/qr_verify.py` 7/7
