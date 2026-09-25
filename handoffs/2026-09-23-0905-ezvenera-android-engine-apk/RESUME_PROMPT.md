# EZVenera for KOReader — Resume Prompt（2026-09-23 引擎 APK 化终态）

你接手一个项目：**EZVenera for KOReader**（在 KOReader LuaJIT 中运行 Venera/EZVenera JS 漫画源插件的移植层，当前优先安卓平板，Kindle 4 暂缓）。

## 项目状态

- **安卓引擎链路全通**（安卓测试平板 / Android 6 / arm64）：引擎 .so 零 patchelf 重编 → 注入 fdroid APK 重签安装 → dlopen/shim/init.js/源注册/navigation 全链稳定，用户真机实测零崩溃（2026-09-23 08:40 logcat 实证）。
- 历史"安卓引擎死刑"（R-D2v5）已推翻，双根因修复：① patchelf --set-soname 损坏 verneed 偏移；② pump 的 LuaJIT 回调竞态（现 pump=no-op）。
- **当前限制**：promise 型源数据（分类/搜索/阅读）因 pump no-op 不可用——源主页只见"搜索"项。
- 回归基线：syntax 12/12 · tests 113/0 · hold clean · vendor OK；全部工作**未提交 git**（建议分批提交）。

## 用户既定决策（必须遵守）

1. **优先安卓平板，Kindle 4 暂缓**；
2. **扫码远程输入（remoteinput）已删除**，不得恢复（AGENTS.md 红线 5）；
3. 引擎随 APK 分发路线已接受（fdroid 自动更新失效为已知代价）；
4. **禁用 patchelf 改 .so**（安卓 ≤6 verneed 损坏，见 HANDOFF 决策记录）；
5. 凭据不入仓（红线 6）。

## 你的第一个动作

1. 读 `AGENTS.md`（红线）→ 本目录 `HANDOFF.md`（**本份为最新**）→ 深度历史按需回溯 `handoffs/2026-09-21-2103-ezv-dual-device-deploy/` 的 ADDENDUM 链（以 ADDENDUM-ENGINE-APK-20260923.md 为最近前驱）
2. 跑检查：`tools\.venv\Scripts\python.exe scripts\run_tests.py`（基线 113/0）
3. 设备验证（平板 USB 连接，adb）：打开 KOReader → 工具 → EZVenera 漫画 → 引擎与状态（应显示"JS 引擎: 已安装"）→ 浏览漫画源 → 点源（主页开、无崩溃 = 现状正常）

## 立即下一步

1. **S2 异步泵**（唯一关键项）：eval 后不内联泵，改 `UIManager:scheduleIn` 主循环节拍逐拍泵 job（每拍 ≤10 个、预算 ≤100ms），回调全部收敛主循环 → 恢复分类/搜索/阅读数据流。注意：**JS_ExecutePendingJob 单次探测也会触发竞态崩溃**，pending 检测需走 glue 侧通知。
2. 真机验证需网络（设备当前无外网；settings 残留代理 <DEV-HOST>:<PROXY-PORT> 未验证）。
3. git 分批提交（扫码删除 / M2 UI / 崩溃修复 / 引擎 APK 化 / handoff）。

## 禁止操作

- patchelf 改任何 .so 的 soname（安卓全线）
- 修改 `vendored/init.js`（ADR-002 锁 sha256）
- 恢复 remoteinput / 任何扫码输入代码
- 用 inspector 驱动引擎 eval/pump 做关键验证（有跨线程竞态伪影，必须用户真机点击）
- 密钥/凭据入仓入文档

## 取证速查

- native 崩溃：`adb shell "dumpsys dropbox --print SYSTEM_TOMBSTONE"`（取最后一条 pid 段）
- 符号化：构建机上 `llvm-symbolizer --obj=~/ezv/EZVenera_KO/build/quickjs-android-old/libqjs.so <vaddr>`
- 引擎日志：logcat 过滤 `ezvenera`（eval 四段 / `bridge <-` 方法名 / pump 注释）
- APK 重打全套：`build/apk-engine/`（build_nopatchelf.sh → make_apk3.sh → ezv.keystore/口令走环境变量）
