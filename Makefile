SHELL := /bin/bash

.PHONY: build build-bash build-go build-rust test test-bash test-go test-rust test-go-e2e test-rust-e2e clean

build: build-bash build-go build-rust

build-bash:
	bash scripts/build.sh dist/agent.sh

build-go:
	mkdir -p go/.gocache go/.gomodcache dist
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go mod download
	@# Patch go-prompt: remove multiline continuation prefix to match Rust rustyline behavior
	bash scripts/patch-go-prompt.sh go/.gomodcache
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go build -ldflags="-s -w" -trimpath -o ../dist/goagent ./cmd/goagent

build-rust:
	cd rust && cargo build --release -j 10
	cp rust/target/release/rustagent dist/rustagent
	strip -x dist/rustagent

test: test-bash test-go test-rust

test-bash:
	bash tests/test.sh

test-go:
	mkdir -p go/.gocache go/.gomodcache
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go mod download
	bash scripts/patch-go-prompt.sh go/.gomodcache
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go test ./...

test-go-e2e: build-go
	AGENT=./dist/goagent bash tests/test.sh

test-rust:
	cd rust && cargo check

test-rust-e2e: build-rust
	AGENT=./dist/rustagent bash tests/test.sh

clean:
	rm -rf go/dist
