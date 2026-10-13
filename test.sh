#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
cargo test --locked --manifest-path core/Cargo.toml
cargo build --locked --manifest-path core/Cargo.toml
mkdir -p build
xcrun swiftc -swift-version 6 Sources/Contracts.swift tests/ContractTests.swift -o build/contract-tests
build/contract-tests "$PWD/core/target/debug/mi-air-core"
xcrun swiftc -swift-version 6 -typecheck Sources/*.swift
