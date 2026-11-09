#!/bin/bash
# Regenerates Resources/AppIcon.icns from the tomato drawing in TomatoIcon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -parse-as-library -o "$TMP/make_icon" Sources/PomodoroTimer/TomatoIcon.swift scripts/make_icon.swift
"$TMP/make_icon" Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
