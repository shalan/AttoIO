#!/usr/bin/env bash
set -e
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$PROJ_ROOT"

FW="${FW:-hd44780}"
TB="${TB:-hd44780}"

HEX=$(attoio_build_fw "$FW")
attoio_compile "tb_$TB" "$PROJ_ROOT/sim/hd44780_model.v"
attoio_run     "tb_$TB"
