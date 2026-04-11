SHELL := /bin/bash

.PHONY: build build-bash build-go build-rust test-go test-rust clean

build: build-bash build-go build-rust

build-bash:
	mkdir -p dist
	cp src/agent.sh dist/agent.sh
	chmod +x dist/agent.sh

build-go:
	mkdir -p go/.gocache go/.gomodcache dist
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go build -o ../dist/goagent ./cmd/goagent

build-rust:
	cd rust && cargo build --release
	cp rust/target/release/rustagent dist/rustagent
	strip -x dist/rustagent

test-go:
	mkdir -p go/.gocache go/.gomodcache
	GOCACHE=$(PWD)/go/.gocache GOMODCACHE=$(PWD)/go/.gomodcache go -C go test ./...

test-rust:
	cd rust && cargo check

clean:
	rm -rf go/dist
