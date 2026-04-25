#!/usr/bin/env bash
set -e
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$PROJ_ROOT"

FW="${FW:-tm1637}"
TB="${TB:-tm1637}"

HEX=$(attoio_build_fw "$FW")
attoio_compile "tb_$TB" "$PROJ_ROOT/sim/tm1637_slave_model.v"
attoio_run     "tb_$TB"
