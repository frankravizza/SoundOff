#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soundoff-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -O Sources/VoiceSettings.swift Sources/AudioCore.swift Tests/AudioTests.swift -o "$TEST_DIR/audio-tests"
"$TEST_DIR/audio-tests"
