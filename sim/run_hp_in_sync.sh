#!/usr/bin/env bash
# tb_hp_in_sync — drives pad_in with a glitchy pattern, asserts that
# hp{0,1,2}_in (now driven through attoio_gpio's 2-flop sysclk sync)
# is never X and tracks pad_in with a 2-cycle delay.
set -e
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$PROJ_ROOT"

FW="${FW:-empty}"
TB="${TB:-hp_in_sync}"

HEX=$(attoio_build_fw "$FW")
attoio_compile "tb_$TB"
attoio_run     "tb_$TB"
