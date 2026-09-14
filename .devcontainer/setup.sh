#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.

# elan and its toolchains live in a named volume shared with every other project
# using this setup, so they are installed here rather than in the Dockerfile: a
# RUN layer is built before the volume is mounted over it, and whatever it
# installed would never be seen again.

set -euo pipefail

if [ -x "$HOME/.elan/bin/elan" ]; then
  # Otherwise elan is frozen at whatever first populated the volume, which may be
  # months older than the image around it.
  elan self update
else
  # PATH already carries ~/.elan/bin, set in the Dockerfile.
  curl -fsSL https://elan.lean-lang.org/elan-init.sh | sh -s -- -y --no-modify-path
fi

# So that the first `lake build` is a build rather than a toolchain download.
elan toolchain install "$(tr -d '[:space:]' < lean-toolchain)"
