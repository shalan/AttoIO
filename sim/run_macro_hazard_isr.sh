#!/usr/bin/env bash
# BUG-002 isolation step 4: same store sequence, but inside an __isr
# fired by a host-side doorbell.  Pass --poll to enable concurrent
# host polling of mailbox[2] during run.
set -e
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$PROJ_ROOT"

FW="${FW:-core_hazard_isr}"
TB="${TB:-macro_hazard_isr}"
[[ "${1:-}" == "--poll" ]] && export IVERILOG_EXTRA="${IVERILOG_EXTRA:-} -DPOLL_HOST"

HEX=$(attoio_build_fw "$FW")
attoio_compile "tb_$TB"
attoio_run     "tb_$TB"
