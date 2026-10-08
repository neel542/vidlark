#!/bin/bash
# Checks the face framing rules on made-up face tracks (no real faces).
# Run: bash Tests/framing/run.sh   (UPDATE_GOLDEN=1 rewrites fixtures/*.path.json after a deliberate change)
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .build
swiftc -O -parse-as-library -o .build/framing-check Sources/vidlark-finish/Framing.swift Tests/framing/check.swift
.build/framing-check Tests/framing/fixtures
