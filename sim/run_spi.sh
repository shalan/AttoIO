#!/usr/bin/env bash
set -e
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$PROJ_ROOT"

FW="${FW:-spi_master}"
TB="${TB:-spi}"

HEX=$(attoio_build_fw "$FW")
attoio_compile "tb_$TB" "$PROJ_ROOT/sim/spi_slave_model.v"
attoio_run     "tb_$TB"
