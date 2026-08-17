SHELL := /bin/bash

.PHONY: build build-bash build-go build-rust build-tcode build-c build-webagent build-webagent-android build-rustagent-android build-deb test test-bash test-go test-rust test-go-e2e test-rust-e2e test-c-e2e test-c-classify test-c-transport update-system-prompt-golden clean

VERSION ?=
DEB_DIST_DIR ?= dist
DEB_OUTPUT_DIR ?= dist

build: build-bash build-go build-rust build-tcode build-c

build-bash:
	bash scripts/build.sh dist/agent.sh

build-go:
	mkdir -p go/.gocache go/.gomodcache dist
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go mod download
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go build -ldflags="-s -w" -trimpath -o ../dist/goagent ./cmd/goagent

build-rust:
	cd rust && cargo build --release -j 10
	cp rust/target/release/rustagent dist/rustagent
	strip -x dist/rustagent

build-tcode:
	cp scripts/tcode dist/tcode
	chmod +x dist/tcode

build-webagent:
	mkdir -p dist
	cd webagent && cargo build --release -j 10
	cp webagent/target/release/webagent dist/webagent
	strip -x dist/webagent

# 交叉编译 rustagent 到 Android (Termux) — 需要 NDK
# 说明：NDK 只有带 API level 的 clang，cc-rs（ring）探测不到
# aarch64-linux-android-clang 通用名，必须用 env 显式指定 CC/AR
# （变量名含 '-'，bash 无法直接赋值，需经 env 命令传入）
NDK_TOOLCHAIN = $(NDK)/toolchains/llvm/prebuilt/darwin-x86_64/bin
ANDROID_CC = $(NDK_TOOLCHAIN)/aarch64-linux-android27-clang
ANDROID_ENV = env 'CC_aarch64-linux-android=$(ANDROID_CC)' 'AR_aarch64-linux-android=$(NDK_TOOLCHAIN)/llvm-ar' CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER='$(ANDROID_CC)'
build-rustagent-android:
	@test -n "$(NDK)" || { echo "用法：make build-rustagent-android NDK=/path/to/android-ndk" >&2; exit 2; }
	cd rust && $(ANDROID_ENV) cargo build --release --target aarch64-linux-android -j 10
	cp rust/target/aarch64-linux-android/release/rustagent dist/rustagent-android

# 交叉编译 webagent 到 Android (Termux) — 需要 NDK
build-webagent-android: build-rustagent-android
	cd webagent && $(ANDROID_ENV) cargo build --release --target aarch64-linux-android -j 10
	cp webagent/target/aarch64-linux-android/release/webagent dist/webagent-android

build-c:
	$(MAKE) -C c

build-deb:
	@test -n "$(VERSION)" || { echo "用法：make build-deb VERSION=4.3.0 [DEB_DIST_DIR=dist] [DEB_OUTPUT_DIR=dist]" >&2; exit 2; }
	bash scripts/build-deb.sh "$(VERSION)" "$(DEB_DIST_DIR)" "$(DEB_OUTPUT_DIR)"

test: test-bash test-go test-rust test-c-e2e

test-bash:
	bash tests/test.sh

test-go:
	mkdir -p go/.gocache go/.gomodcache
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go mod download
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go test ./...

test-go-e2e: build-go
	AGENT=./dist/goagent bash tests/test.sh

test-rust:
	cd rust && cargo check
	cargo test --manifest-path rust/Cargo.toml native_file_mode_guard_matches_bash

test-rust-e2e: build-rust
	AGENT=./dist/rustagent bash tests/test.sh

test-c-e2e: build-c
	AGENT=./dist/cagent bash tests/test.sh

test-c-classify: build-c
	$(MAKE) -C c test-classify

test-c-transport:
	$(MAKE) -C c test-transport

update-system-prompt-golden: build-bash
	bash scripts/update-system-prompt-golden.sh

clean:
	rm -rf go/dist rust/target webagent/target dist/cagent
	$(MAKE) -C c clean
