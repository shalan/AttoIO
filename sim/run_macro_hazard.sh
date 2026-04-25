#!/usr/bin/env bash
# BUG-002 isolation: same core_hazard FW, but wrapped in attoio_macro.
# Pass --poll to enable concurrent host polling of mailbox during run.
set -e
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$PROJ_ROOT"

FW="${FW:-core_hazard}"
TB="${TB:-macro_hazard}"
[[ "${1:-}" == "--poll" ]] && export IVERILOG_EXTRA="${IVERILOG_EXTRA:-} -DPOLL_HOST"

HEX=$(attoio_build_fw "$FW")
attoio_compile "tb_$TB"
attoio_run     "tb_$TB"
