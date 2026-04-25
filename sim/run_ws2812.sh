#!/usr/bin/env bash
set -e
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$PROJ_ROOT"

FW="${FW:-ws2812}"
TB="${TB:-ws2812}"

HEX=$(attoio_build_fw "$FW")
attoio_compile "tb_$TB" 
attoio_run     "tb_$TB"
