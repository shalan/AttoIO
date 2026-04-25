#!/usr/bin/env bash
set -e
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$PROJ_ROOT"

FW="${FW:-irq_aggregate}"
TB="${TB:-irq_aggregate}"

HEX=$(attoio_build_fw "$FW")
attoio_compile "tb_$TB" 
attoio_run     "tb_$TB"
