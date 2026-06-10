SHELL := /bin/bash

.PHONY: build build-bash build-go build-rust build-tcode build-c build-deb test test-bash test-go test-rust test-go-e2e test-rust-e2e test-c-e2e test-c-classify update-system-prompt-golden clean

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

build-rust2:
	cd rust2 && cargo build --release -j 10
	cp rust2/target/release/rust2agent dist/rust2agent
	strip -x dist/rust2agent

build-tcode:
	cp scripts/tcode dist/tcode
	chmod +x dist/tcode

build-c:
	$(MAKE) -C c

build-deb:
	bash scripts/build-deb.sh "$${VERSION:-$$(git describe --tags --always 2>/dev/null || echo 0.0.0)}" dist dist

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

test-rust-e2e: build-rust
	AGENT=./dist/rustagent bash tests/test.sh

test-c-e2e: build-c
	AGENT=./dist/cagent bash tests/test.sh

test-c-classify: build-c
	$(MAKE) -C c test-classify

update-system-prompt-golden: build-bash
	bash scripts/update-system-prompt-golden.sh

clean:
	rm -rf go/dist rust/target dist/cagent
	$(MAKE) -C c clean
