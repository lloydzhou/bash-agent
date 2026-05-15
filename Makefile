SHELL := /bin/bash

.PHONY: build build-bash build-go build-go2 build-rust build-rust2 test test-bash test-go test-go2 test-rust test-rust2 test-go-e2e test-go2-e2e test-rust-e2e test-rust2-e2e clean

build: build-bash build-go build-go2 build-rust build-rust2

build-bash:
	bash scripts/build.sh dist/agent.sh

build-go:
	mkdir -p go/.gocache go/.gomodcache dist
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go mod download
	@# Patch go-prompt: remove multiline continuation prefix to match Rust rustyline behavior
	bash scripts/patch-go-prompt.sh go/.gomodcache
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go build -ldflags="-s -w" -trimpath -o ../dist/goagent ./cmd/goagent

build-go2:
	mkdir -p go2/.gocache go2/.gomodcache dist
	GOCACHE=$(PWD)/go2/.gocache GOMODCACHE=$(PWD)/go2/.gomodcache go -C go2 mod download
	GOCACHE=$(PWD)/go2/.gocache GOMODCACHE=$(PWD)/go2/.gomodcache go -C go2 build -ldflags="-s -w" -trimpath -o ../dist/go2agent ./cmd/goagent

build-rust:
	cd rust && cargo build --release -j 10
	cp rust/target/release/rustagent dist/rustagent
	strip -x dist/rustagent

build-rust2:
	cd rust2 && cargo build --release -j 10
	cp rust2/target/release/rust2agent dist/rust2agent
	strip -x dist/rust2agent

test: test-bash test-go test-go2 test-rust test-rust2

test-bash:
	bash tests/test.sh

test-go:
	mkdir -p go/.gocache go/.gomodcache
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go mod download
	bash scripts/patch-go-prompt.sh go/.gomodcache
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go test ./...

test-go2:
	mkdir -p go2/.gocache go2/.gomodcache
	GOCACHE=$(PWD)/go2/.gocache GOMODCACHE=$(PWD)/go2/.gomodcache go -C go2 mod download
	GOCACHE=$(PWD)/go2/.gocache GOMODCACHE=$(PWD)/go2/.gomodcache go -C go2 test ./...

test-go-e2e: build-go
	AGENT=./dist/goagent bash tests/test.sh

test-go2-e2e: build-go2
	AGENT=./dist/go2agent bash tests/test.sh

test-rust:
	cd rust && cargo check

test-rust2:
	cd rust2 && cargo check

test-rust-e2e: build-rust
	AGENT=./dist/rustagent bash tests/test.sh

test-rust2-e2e: build-rust2
	AGENT=./dist/rust2agent bash tests/test.sh

clean:
	rm -rf go/dist go2/dist rust/target rust2/target
