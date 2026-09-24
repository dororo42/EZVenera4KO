# EZVenera for KOReader — 工作流管理入口
# 常用任务统一入口（Windows 用 tools/.venv\Scripts\python.exe，CI/Linux 用 python3）

ifeq ($(OS),Windows_NT)
    PY := tools/.venv/Scripts/python.exe
    SEP := \#
else
    PY := tools/.venv/bin/python
    SEP := ;
endif

.PHONY: test syntax hold vendor check engine-fetch engine-host engine-android apk-patch apk-sign package dist

test:
	$(PY) scripts/run_tests.py

syntax:
	$(PY) scripts/check_syntax.py

hold:
	$(PY) scripts/check_no_hold.py

vendor:
	$(PY) scripts/verify_vendored.py

# 一键全检（提交前跑这个；CI 等价物）
check:
	$(MAKE) syntax
	$(MAKE) test
	$(MAKE) hold
	$(MAKE) vendor

# quickjs 引擎（S2 里程碑）
engine-fetch:
	bash scripts/fetch-quickjs.sh

engine-host:
	bash scripts/build-quickjs.sh x86_64

# 安卓 arm64 引擎（需 NDK=...；零 patchelf 配方，产物 build/android-engine/）
engine-android:
	NDK=$(NDK) bash scripts/android/build-engine-android.sh $(ENGINE_ARGS)

# APK 注入引擎 + 重签名（凭据走 KEYSTORE/KS_PASS 环境变量）
apk-patch:
	python3 scripts/android/patch-apk.py $(APK_IN) $(APK_OUT) build/android-engine

apk-sign:
	KEYSTORE=$(KEYSTORE) KS_PASS=$(KS_PASS) bash scripts/android/sign-apk.sh $(APK_IN) $(APK_OUT)

# Kindle MRPI 包
package:
	bash scripts/package-mrpi.sh
