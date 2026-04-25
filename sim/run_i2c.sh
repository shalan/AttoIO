#!/usr/bin/env bash
set -e
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$PROJ_ROOT"

FW="${FW:-i2c_eeprom}"
TB="${TB:-i2c}"

HEX=$(attoio_build_fw "$FW")
attoio_compile "tb_$TB" "$PROJ_ROOT/sim/i2c_eeprom_model.v"
attoio_run     "tb_$TB"
