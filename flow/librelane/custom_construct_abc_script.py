# Custom construct_abc_script.py — drop-in replacement that overrides the
# "AREA 0" strategy with a user-supplied recipe while leaving AREA 1..3
# and DELAY 0..4 identical to the LibreLane default.
#
# Bind-mount into the LibreLane container over:
#   /nix/store/ql4nbdxqdd9ph8x1k8awi7yklk8rx51j-python3-3.13.9-env/
#     lib/python3.13/site-packages/librelane/scripts/pyosys/
#       construct_abc_script.py
#
# Reference: original LibreLane construct_abc_script.py (Efabless, 2020-2024).

import os
import re


# ---------------------------------------------------------------------------
# User-supplied "AREA 0" custom recipe.
#
# The {D} token is substituted with the clock period in picoseconds
# (same convention the LibreLane default uses).
# ---------------------------------------------------------------------------
CUSTOM_AREA0_RECIPE = """\
strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
ifraig; scorr; dc2; dretime; strash
&get -n
&dch -f
&nf {D}
&put
buffer -c
topo
upsize {D} -c
dnsize {D} -c
"""


class ABCScriptCreator:
    def __init__(self, config):
        self.config = config
        D = config["CLOCK_PERIOD"] * 1000  # ns -> ps
        self.D = D

        self.rs_K = "resub -K "
        self.rs = "resub"
        self.rsz = "resub -z"
        self.rf = "drf -l"
        self.rfz = "drf -l -z"
        self.rw = "drw -l"
        self.rwz = "drw -l -z"
        self.rw_K = "drw -l -K"

        if config["SYNTH_ABC_LEGACY_REFACTOR"]:
            self.rf = "refactor"
            self.rfz = "refactor -z"

        if config["SYNTH_ABC_LEGACY_REWRITE"]:
            self.rw = "rewrite"
            self.rwz = "rewrite -z"
            self.rw_K = "rewrite -K"

        self.b = "balance"
        self.resyn2 = f"{self.b}; {self.rw}; {self.rf}; {self.b}; {self.rw}; {self.rwz}; {self.b}; {self.rfz}; {self.rwz}; {self.b}"
        self.share = f"strash; multi -m; {self.resyn2}"
        self.resyn2a = f"{self.b};{self.rw};{self.b};{self.rw};{self.rwz};{self.b};{self.rwz};{self.b}"
        self.resyn3 = f"{self.b}; resub; resub -K 6; {self.b};resub -z;resub -z -K 6; {self.b};resub -z -K 5; {self.b}"
        self.resyn2rs = f"{self.b};{self.rs_K} 6;{self.rw};{self.rs_K} 6 -N 2;{self.rf};{self.rs_K} 8;{self.rw};{self.rs_K} 10;{self.rwz};{self.rs_K} 10 -N 2;{self.b} {self.rs_K} 12;{self.rfz};{self.rs_K} 12 -N 2;{self.rwz};{self.b}"

        self.choice = f"fraig_store; {self.resyn2}; fraig_store; {self.resyn2}; fraig_store; fraig_restore"
        self.choice2 = f"fraig_store; {self.b}; fraig_store; {self.resyn2}; fraig_store; {self.resyn2}; fraig_store; {self.resyn2}; fraig_store; fraig_restore"

        self.area_mfs3 = ""
        self.delay_mfs3 = ""
        if config["SYNTH_ABC_USE_MFS3"]:
            self.area_mfs3 = "mfs3 -aemvz -I 4 -O 2"
            self.delay_mfs3 = "mfs3 -emvz -I 4 -O 2"

        self.map_old_area = "map -p -a -B 0.2 -A 0.9 -M 0"
        self.map_old_dly = "map -p -B 0.2 -A 0.9 -M 0"
        self.retime_area = "retime -M 5"
        self.retime_dly = "retime -M 6"
        self.map_new_area = "amap -m -Q 0.1 -F 20 -A 20 -C 5000"

        if config["SYNTH_ABC_AREA_USE_NF"]:
            self.map_new_area = "&get -n; &nf -R 1000; &put"

        self.max_fanout = config["MAX_FANOUT_CONSTRAINT"]
        self.max_transition = (
            config.get("MAX_TRANSITION_CONSTRAINT") or 0
        ) * 1000  # ns -> ps
        self.fine_tune = ""
        if config["SYNTH_ABC_BUFFERING"]:
            max_tr_arg = ""
            if self.max_transition != 0:
                max_tr_arg = f" -S {self.max_transition}"
            self.fine_tune = f"buffer -N {self.max_fanout}{max_tr_arg};upsize;dnsize"
        elif config["SYNTH_SIZING"]:
            self.fine_tune = "upsize;dnsize"

    def generate_abc_script(self, step_dir, strategy):
        strategy_clean = re.sub(r"\s+", "_", strategy)
        abc_script_path = os.path.join(step_dir, f"{strategy_clean}.abc")
        f = open(abc_script_path, "w")

        # -------------------------------------------------------------
        # *** CUSTOM OVERRIDE: AREA 0 uses the user-supplied recipe ***
        # -------------------------------------------------------------
        if strategy == "AREA 0":
            recipe = CUSTOM_AREA0_RECIPE.replace("{D}", str(int(self.D)))
            f.write(recipe)
            print("stime -p", file=f)
            print("print_stats -m", file=f)
            f.close()
            print(f"[CUSTOM ABC] wrote {abc_script_path} ({len(recipe.splitlines())} cmds)")
            return abc_script_path

        # -------------------------------------------------------------
        # Everything below is identical to the stock LibreLane script.
        # -------------------------------------------------------------
        if strategy == "AREA 3":
            print("strash", file=f)
            print("dch", file=f)
            print("map -B 0.9", file=f)
            print("topo", file=f)
            print("stime -c", file=f)
            print(f"buffer -c -N {self.max_fanout}", file=f)
            print("upsize -c", file=f)
            print("dnsize -c", file=f)
        elif strategy == "DELAY 4":
            def repeated_sequence(f):
                print("&st", file=f)
                print("&syn2", file=f)
                print("&if -g -K 6", file=f)
                print("&synch2", file=f)
                print("&nf", file=f)

            print("&get -n", file=f)
            print("&st", file=f)
            print("&dch", file=f)
            print("&nf", file=f)

            for _ in range(5):
                repeated_sequence(f)

            print("&put", file=f)
            print(f"buffer -c -N {self.max_fanout}", file=f)
            print("topo", file=f)
            print("stime -c", file=f)
            print("upsize -c", file=f)
            print("dnsize -c", file=f)
        else:
            print("fx", file=f)
            print("mfs", file=f)
            print("strash", file=f)
            print(self.rf, file=f)

            if strategy == "AREA 2":
                print(self.choice2, file=f)
            else:
                print(self.resyn2, file=f)
            if strategy.startswith("AREA ") or strategy == "DELAY 3":
                print(self.retime_area, file=f)
            else:
                print(self.retime_dly, file=f)
            print("scleanup", file=f)

            if strategy in ["AREA 4", "DELAY 2"]:
                print(self.choice, file=f)
            elif strategy != "DELAY 0":
                print(self.choice2, file=f)
            if strategy.startswith("AREA ") or strategy == "DELAY 3":
                print(self.map_new_area, file=f)
            else:
                print(self.map_old_dly, file=f)

            if strategy in ["AREA 1", "AREA 2"]:
                print(self.choice2, file=f)
                print(self.map_new_area, file=f)
            elif strategy in ["DELAY 1"]:
                print(self.choice2, file=f)
                print("map", file=f)
            elif strategy in ["DELAY 2"]:
                print(self.choice, file=f)
                print("map", file=f)
            elif strategy in ["DELAY 3"]:
                print(self.choice2, file=f)
                print(self.map_old_dly, file=f)

            if strategy.startswith("AREA "):
                print(self.area_mfs3, file=f)
            else:
                print(self.delay_mfs3, file=f)

            print("retime", file=f)

            print("&get -n", file=f)
            print("&st", file=f)
            print("&dch", file=f)
            print("&nf", file=f)
            print("&put", file=f)
            print(self.fine_tune, file=f)

        print("stime -p", file=f)
        print("print_stats -m", file=f)
        f.close()
        return abc_script_path
