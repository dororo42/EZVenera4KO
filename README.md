<!--
EZVenera for KOReader — 项目 README
当前状态：M2（源管理 + 浏览/搜索/阅读 + 下载缓存 + 收藏历史）；主力设备 = 安卓触屏平板。
-->

# EZVenera for KOReader

在 **KOReader（LuaJIT）** 里直接跑 Venera / EZVenera 的 JS 漫画源：原版 `.js` 源
（`class X extends ComicSource`）**不改一行**即可浏览、搜索、翻页阅读、离线下载。

引擎 = quickjs-ng（FFI `.so`）+ Lua 宿主 API；触屏与按键设备都可用（全部入口均为普通菜单项，
不依赖长按）。**当前主力设备：安卓平板**（实测环境：Android 6 / arm64 / KOReader v2026.07.1）。
Kindle 4（非触屏）代码保留但本轮冻结。

## 已实现功能

| 分类 | 内容 |
|---|---|
| 源管理 | 官方索引浏览安装 / **从 URL 直装 `.js`** / **添加自定义 `index.json` 索引** / 从本地文件安装 / 已安装源查看·参数配置·删除 |
| 浏览 | 源主页 → 分类·搜索 → 结果列表 → 详情 → 章节列表；下拉翻页；收藏与阅读历史 |
| 阅读 | 逐页图片流（惰性加载 + 内存上限）、章节内前后翻页、**章节切换 + 章节列表跳转**、离线优先读取 |
| 下载 | 整章离线下载（逐页节拍、可取消、失败重试）、下载与缓存管理（占用统计 / 单条清理 / 全清） |
| 网络 | 插件自带 HTTP 层，**per-request 代理**（http/https 都走，不依赖 KOReader 全局代理）、Cookie jar、连通性自测 |
| 集成 | Dispatcher 动作（可绑手势/快捷键）、[SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) 磁贴自动注册（装了才注册，没装静默） |
| 稳定 | JS/网络异常全部收口在插件内（崩溃链已修），安卓主循环联网受控（消除「KOReader 无响应」） |

菜单入口：**≡ 菜单 → 工具 → EZVenera 漫画**

```
EZVenera 漫画
├── 浏览漫画源                 # 已装源列表 → 分类/搜索 → 结果 → 详情 → 阅读
├── 收藏夹 / 阅读历史
├── 下载与缓存
├── 管理漫画源
│   ├── 浏览索引并安装          # 拉官方索引（GitHub raw，CDN/http 自动回退）
│   ├── 从 URL 添加源（.js 直装）
│   ├── 添加自定义源索引（index.json）
│   ├── 已添加的自定义索引      # 查看 / 删除
│   ├── 从本地文件添加源
│   └── 已安装源（查看/删除）   # 含账号/密码/自定义网址等参数配置
├── 网络代理                   # 启用·禁用 / 编辑地址 / 测试连通
├── 引擎与状态                 # JS 引擎、桥、依赖的诊断信息（排查用）
└── 自检(排查用)               # 开发者用的诊断项，出问题时先看这里
```

## 环境要求

- **KOReader ≥ 2026.07**（实测 `v2026.07.1`，F-Droid 包）。
- JS 引擎的两个 `.so`（`libquickjs.so` + `libezvbridge.so`）**不入 git**（见 `.gitignore`
  的 `*.so`），必须自己构建或从 Releases 下载 —— 见下方步骤 2。
  没有引擎时插件仍能列出已装源，但无法浏览/阅读。
- 部分源站需要代理：先在「网络代理 → 编辑代理地址」填 `http://host:port`（默认空）。

## 安装

### 步骤 0 — 取代码

```bash
git clone https://github.com/dororo42/EZVenera4KO.git
cd EZVenera4KO
```

### 步骤 1 — 把插件放进 KOReader 的 plugins 目录

**安卓（推荐 adb）**

```bash
# KOReader 的数据目录在 /sdcard/koreader（首次启动 KOReader 后会生成）
adb push src/koreader-plugin/ezvenera.koplugin /sdcard/koreader/plugins/
```

没有 adb 就用文件管理器：把 `src/koreader-plugin/ezvenera.koplugin` **整个目录**
复制到手机 `内部存储/koreader/plugins/` 下。

**Kindle / 桌面 KOReader**

复制到 `<KOReader 目录>/plugins/`，结果应是 `plugins/ezvenera.koplugin/main.lua`。
Kindle 上可用打包脚本：`bash scripts/package-mrpi.sh`。

重启 KOReader → ≡ 菜单 → 工具 → 应能看到 **EZVenera 漫画**。

### 步骤 2 — 装 JS 引擎（三选一）

**路线 A：下载预编译（最省事）**

到本仓库 **Releases** 下载 `ezvenera-engine-android-arm64.zip`（内含两个 `.so`），
解压到 `plugins/ezvenera.koplugin/lib/`。校验值（sha256）：

```
bfde74482ef305ffeb5b2063346b2f4a80cd2a8593b997dcd34d6c37a33efc71  libquickjs.so   (809768 B)
cf059336f092272b7cc5918a3a63c3bed7404242d3b053ae816f357187bfc243  libezvbridge.so (5712 B)
```

这两份就是 2026-09-23 真机（安卓测试平板 / Android 6 / arm64）跑通 dlopen→桥→init.js→源 JS
全链的那一批，从已验证的构建产物里原样取出。

**路线 B：注入 KOReader APK（安卓真机实测路线）**

Android 上 SELinux 禁止从 `/sdcard` dlopen，所以引擎要放进 APK 的
`lib/arm64-v8a/`，再重新签名安装。需要 Linux/WSL + Android NDK +
`zipalign`/`apksigner`：

```bash
# 1) 拉 quickjs-ng 源码（校验 sha256 后解压到 rust/ezvjs-bridge/vendor/）
bash scripts/fetch-quickjs.sh

# 2) 交叉编译引擎 + 桥（产物 build/android-engine/*.so，末尾自动做 ELF 校验）
NDK=$HOME/android-ndk bash scripts/android/build-engine-android.sh

# 3) 下载官方 KOReader APK（F-Droid 或 GitHub Releases），注入引擎
python3 scripts/android/patch-apk.py \
    /path/to/koreader-fdroid.apk /tmp/ezv-unsigned.apk build/android-engine

# 4) 对齐 + 重签名（keystore 自己生成；口令走环境变量，别写进文件）
keytool -genkeypair -v -keystore ~/ezv.keystore -alias ezv \
        -keyalg RSA -keysize 2048 -validity 10000
KEYSTORE=$HOME/ezv.keystore KS_PASS='你的口令' \
    bash scripts/android/sign-apk.sh /tmp/ezv-unsigned.apk /tmp/ezv-signed.apk

# 5) 安装（签名与官方包不同 → 必须先卸载，阅读进度在 /sdcard/koreader 下不会丢）
adb uninstall org.koreader.launcher.fdroid
adb install /tmp/ezv-signed.apk
```

代价：F-Droid/Play 的自动更新会因签名不符失效，升级 KOReader 时对新版 APK 重跑第 3–5 步。

**路线 C：桌面 / Kindle 直接编**

```bash
bash scripts/build-quickjs.sh x86_64      # 本机或 CI
bash scripts/build-shim.sh                # 产出 lib/libezvbridge.so
# Kindle：先装 koxtoolchain，再按 kindle 目标各编一遍
bash scripts/build-quickjs.sh kindle
bash scripts/build-shim.sh --target kindle
# 产物落到 plugins/ezvenera.koplugin/lib/ 即可
```

> 安卓构建脚本刻意**不用 patchelf**：`patchelf --set-soname` 会破坏 verneed 的
> 字符串表偏移，Android ≤6 的 linker 因此拒载（真机表现为 dlopen 失败 + 乱串符号名）。

### 步骤 3 — 首次配置

1. **代理**（源站在你这边不通时才需要）：工具 → EZVenera 漫画 → 网络代理 →
   编辑代理地址（例：`http://192.0.2.10:7890`，文档用 TEST-NET 地址）→ 启用代理 → 测试连通。
2. **加源**：管理漫画源 → 浏览索引并安装 → 选一条 → 安装。
   有别人的索引或单个 `.js`：用「添加自定义源索引（index.json）」/「从 URL 添加源」。
3. **看漫画**：浏览漫画源 → 选源 → 分类或搜索 → 结果 → 详情 → 章节 → 阅读。
   想离线：详情页或章节菜单里下载整章；「下载与缓存」里管理占用。

### 数据存放位置

| 内容 | 路径 |
|---|---|
| 已安装源 JS | `<koreader>/ezvenera/sources/<key>.js` |
| 已安装清单 | `<koreader>/ezvenera/installed.json` |
| 自定义索引 | `<koreader>/ezvenera/index/custom_*.json`（同名 `.base` 记录索引基址） |
| 下载缓存 | `<koreader>/ezvenera/downloads/` |
| 收藏·历史·源参数 | `<koreader>/ezvenera/data/` |

安卓上是 `/sdcard/koreader/ezvenera/`。备份/迁移直接把整个 `ezvenera/` 目录拷走。

## 开发与验证

```bash
python -m venv tools/.venv
tools/.venv/Scripts/pip install lupa      # Windows
# tools/.venv/bin/pip install lupa        # Linux/macOS

make check        # = 语法 + 单测 + 无长按红线 + vendored 校验（≈CI 等价物；CI 另含 cargo check）
```

四道闸门（`scripts/`）：

| 脚本 | 作用 |
|---|---|
| `check_syntax.py` | 全部 Lua 语法检查 |
| `run_tests.py` | lupa(LuaJIT) 跑 `tests/*.lua`（当前 267 项） |
| `check_no_hold.py` | **红线**：插件目录内不得出现长按（hold）依赖 —— ADR-005 |
| `verify_vendored.py` | `vendored/init.js` sha256 完整性 —— ADR-002 |

架构与决策见 `changes/ezvenera-koreader-port/design.md`（ADR）与 `specs/requirements.md`；
真机调试笔记见 `handoffs/`。

## 已知限制

- **重签 APK 后 KOReader 官方更新失效**（路线 B 的固有代价）。
- 阅读长章节时图片吃内存，已用惰性加载 + 上限；低内存设备建议逐章下载而非在线拉。
- 部分源要登录/填自定义网址，参数在「已安装源 → 配置」里改；源的可用性取决于源站本身。
- Kindle 4 本轮冻结；恢复时按零 patchelf 配方重编 `kindle` 目标。

## 许可与第三方归属

- 本项目 **GPL-3.0**（见 `LICENSE`），与 KOReader 同许可系。
- `src/koreader-plugin/ezvenera.koplugin/vendored/init.js` 逐字节 vendor 自
  [WEP-56/EZVenera](https://github.com/WEP-56/EZVenera) 的 `assets/init.js`
  （commit `bee3718`，**GPL-3.0**，已核实），头部保留来源与校验声明，
  sha256 由 `verify_vendored.py` 把守。
- JS 引擎 [quickjs-ng](https://github.com/quickjs-ng/quickjs)（BSD-2-Clause）
  由 `scripts/fetch-quickjs.sh` 在构建时下载，**不随本仓库分发**。
- 漫画源 JS 脚本版权归各源作者，本仓库不分发任何源脚本。
