#!/usr/bin/env bash
# tb_pinmux_ngpio8 explicitly tests the DFFRAM attoio_macro at NGPIO=8.
# It is NOT meant to run against the CFSRAM variant (which has NGPIO=16).
set -e
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$PROJ_ROOT"

if [[ "$VARIANT" == "cfsram" ]]; then
    echo "tb_pinmux_ngpio8: SKIPPED (DFFRAM-only test)"
    exit 0
fi

FW="${FW:-empty}"
TB="${TB:-pinmux_ngpio8}"

HEX=$(attoio_build_fw "$FW")
attoio_compile "tb_$TB"
attoio_run     "tb_$TB"
