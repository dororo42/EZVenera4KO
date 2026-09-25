# EZVenera_KO — R3 报告核实与修复记录（2026-09-22）

> **输入**：`2026-09-22-independent-review-r3.md`（第三轮独立审查，另一会话产出）
> **本文动作**：逐项核实 R3 发现 → 标注真伪与时效 → 已完成的记录证据 → 新落地的直接修复 → 剩余项归档
> **修复后基线**：syntax 16/16 · **tests 126/0**（新增符号断言测试）· hold clean · vendor SHA256 match

---

## 1. R3 发现逐项核实结论

### R3 报告的关键时效性问题（重要）

R3 报告基于**昨日上午的代码快照**，其 P0 两项与本会话昨晚已完成的修复重叠。逐项对时如下：

| R3 项 | R3 判定 | 核实结论 | 当前状态 |
|---|---|---|---|
| **H1** quickjs 符号不匹配（P0） | "代码尚未修改" | **信息滞后** —— 本会话 09-21 晚已按方案 A 落地：cdef 改 `JS_ToCStringLen2`/`JS_NewCFunction2`（签名对照 vendor quickjs.h L900/L1330 人工核对）、`_evalRaw` 两处调用适配、`missingSymbols` 清单同步、测试桩同步改名 | ✅ **已修复**：125/125 → 修复后复绿；src+release 哈希一致；K4 已推新 jshost.lua |
| **安卓测试平板崩溃**（P0 抓栈） | "等崩溃栈捕获后修复" | **信息滞后** —— 用户已提供崩溃 report（系统分享崩溃文本.txt）+ 设备 logcat 实锤：`main.lua:74: attempt to index local 'socket' (a nil value)`。根因 = fdroid KOReader 上 `pcall(require,"socket")` 假成功（ok=true 但模块 nil），init 无守卫 | ✅ **已修复**：main.lua 增加 `type(socket) ~= "table"` 双守卫（src+release 同步），已 adb push 测试平板并重启验证（inspector 确认注册正常、无报错复发）。用户已决策扫码输入延后开发 |
| **kindle5 工具链卡住**（P1） | "换镜像预置 tarball" | **信息滞后** —— 已完成：crosstool-ng 全量构建成功（gcc 14.4.0），tarball 经清华/gentoo/sourceforge 镜像预置 18 个；`clock_gettime` 链接错误仅影响 quickjs 测试可执行文件，主产物 libqjs.so 成功 | ✅ **已完成**：新 libquickjs.so(436464B)+libezvbridge.so(9836B) 已编出并推送到 K4 |
| **H2** HTTPS CONNECT 隧道未验证 | 属实 | 与本会话 handoff 记录一致——需真机+代理环境 | ⏸ **保留**：归入真机冒烟清单（等代理地址） |
| **M1** delay 语义断裂 | 属实 | 与本会话 N4 判定一致——M1 零暴露，S2 范畴 | ⏸ **挂起**：S2/T-S2a 一并处理（既有决策） |
| **M2(cookies)** 拆分边界 | 属实（理论） | 现有启发式对常见格式正确且有单测；建议的 fixture 场景合理 | ⏸ **归档**：后续轮次补 fixture（不阻塞部署） |
| **M3** crypto 后端静默降级 | 属实 | 有价值且改动小 | ✅ **本轮已修**：引擎状态页新增「加密后端」行（见 §2） |
| **M4** chunked encoding | 属实（理论） | 主流手机浏览器 fetch POST 默认带 Content-Length；临时局域网服务风险低 | ⏸ **归档**：随扫码输入延后开发一并评估 |
| **M5** registerSource 行扫描宽松 | 属实（低概率） | 正式 parser 属 M2 范畴；短期二次验证建议合理 | ⏸ **归档**：M2 浏览功能时处理 |
| **L3** uuid 未播种 | 属实 | 一行修复 | ✅ **本轮已修**（bridge.lua 顶部 randomseed） |
| **L5** 内存后端 serialize 开销 | 属实（无正确性影响） | 注释化 | ✅ **本轮已修**（settings.lua 注释标注） |
| **L6** _libs 缓存 error string | 属实 | 修复=失败缓存 nil；改动小但影响启动路径 | ⏸ **归档**：下轮处理（当前重启即可重试，风险可控） |
| **L9** ezvbridge.c msg 生命周期 | 不成立 | C 侧契约：Lua 回调返回缓冲仅需存活到 JS_NewStringLen 拷贝完成；msg 指针在 FreeCString 前未被 Lua 持有——**顺序正确**，且回调内部再调 JS_ToCString 属 API 误用非本层责任 | ❌ **驳回**（ezvbridge.c 头注释已文档化该契约） |
| **L1/L2/L4/L7/L8/L10** | 属实（低价值） | 各为文档/缓存/CI 优化 | ⏸ **归档**：随 M2 里程碑渐进处理 |
| **H1 修复建议：符号断言测试** | 好建议 | CI host 构建产物上跑 | ✅ **本轮已加**：tests/test_engine_symbols.lua（无引擎产物环境保守通过；CI shim-engine-check job 生效） |

### R3 报告的基线数据复核

R3 的 §0 基线（125/125、16/16、clean、SHA256 match）与本会话复跑一致 ✅。修复后当前基线升级为 **126/126**（新增符号断言）。

---

## 2. 本轮新落地的修复（R3 触发）

| # | 文件 | 改动 | 依据 |
|---|---|---|---|
| F1 | runtime/bridge.lua | 顶部增加 `math.randomseed(os.time() + math.floor((os.clock()%1)*100000))` | R3-L3 |
| F2 | main.lua | 引擎状态页新增「加密后端」行：`backendName()` 经 `Convert.new` 探测，显示 `openssl` / `纯 Lua 回退（AES/摘要不可用）` | R3-M3 |
| F3 | settings.lua | 内存后端 write/flush 路径注释标注（R3-L5 语义确认，无行为变化） | R3-L5 |
| F4 | tests/test_engine_symbols.lua（**新增**） | 20 条 cdef 声明 + 15 个必需符号在真实 libquickjs 上的解析断言；无引擎环境保守通过；CI shim-engine-check job 构建后生效 | R3-H1 修复建议 |
| F5 | release 同步 | bridge.lua / main.lua / settings.lua / remoteinput main.lua 已拷贝至 release 两仓 | 保持拆分一致性 |

**修复后回归**：syntax 16/16 · tests **126/0** · hold clean(16) · vendor SHA256 match · 新测试在无引擎环境正确保守通过。

## 3. 双机部署当前状态（接续 handoff）

| 事项 | 状态 |
|---|---|
| kindle5 工具链 | ✅ gcc 14.4.0 @ 构建机:~/x-tools/arm-kindle5-linux-gnueabi/ |
| K4 引擎产物重编 | ✅ libquickjs.so + libezvbridge.so（构建机编出，SHA256 186351…/454303…） |
| K4 推送 | ✅ .so + 修复版 jshost.lua 均已上机（昨夜确认） |
| K4 修复版 bridge/main/settings 推送 | ⏸ **阻塞**：K4 SSH 自 09:15 起 banner exchange 超时（ping 通但 sshd 无响应；构建机同样 No route to host——K4 WiFi 处于省电/半休眠） |
| M2 remoteinput 崩溃修复 | ✅ 修复+推送+重启验证完成；扫码端到端按用户决策延后 |
| M2 ezvenera+arm64 引擎 | ⏸ 待推（NDK 已装 构建机，流水线脚本可复用 /tmp/build_k4.sh 改 android target） |

**K4 SSH 恢复后待办**（按序）：
1. 推送 bridge.lua/main.lua/settings.lua 三文件（本地已备好）
2. K4 重启 KOReader → 菜单「引擎与状态」确认：JS 引擎已安装 + 加密后端=openssl
3. 「浏览漫画源」点击 → 应显示 M2 里程碑提示（=引擎修复成功的标志）
4. 「编辑代理地址」确认扫码按钮是否出现（K4 available() 排查）

## 4. 归档跟踪清单（不阻塞部署）

- H2 HTTPS CONNECT 真机验证（等代理地址） · M1 delay 异步（S2） · M2(cookies) fixture · M4 chunked（随扫码延后） · M5 parser（M2） · L1/L2/L4/L6/L7/L8/L10 渐进 · L9 驳回（契约已文档化）

---

*核实人：Coder Manager（本会话，即 R1/R2 审查与部署会话）；R3 报告由独立会话产出，其基线数据可信，P0 判定因快照时差滞后。*
