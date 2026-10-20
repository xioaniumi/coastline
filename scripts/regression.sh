#!/bin/zsh
# End-to-end regression over the four holding paths: each runs the app headless-ish via
# COASTLINE_SCRIPT on a COPY of an inventory (never the real one), generates every program and
# writes the guided .crproj, then checks that everything passed.
#
#   scripts/regression.sh path/to/inventory.json
#
# A  pendant, 150×40×20 bar straight into the clamp kit
# B  plaque (6×90×4 mm), the whole job flat on the bed
# C  pendant, 150×80×20 bar milled down on the bed first
# D  pendant at 160 %, too tall for the kit: shoulders at the bar's ends
# E–H the example parts (resources/examples, Examples.swift), each with its own bar and holding:
#    E watch bridge (one clamp), F signet pendant (two sides, tabs), G pocket rule (bed), H motor mount (shoulders)
set -u
ROOT=${0:A:h:h}
INV=${1:?inventory json}
OUT=$(mktemp -d /tmp/coastline-regression.XXXX)
APP=$ROOT/Coastline/.build/debug/Coastline
[[ -x $APP ]] || { echo "build the app first (scripts/build-app.sh)"; exit 1; }
python3 - "$INV" "$OUT/inv.json" <<'PY'
import json, sys, uuid
d = json.load(open(sys.argv[1]))
base = dict(d["stock"][0]) if d.get("stock") else {"finish": "sawn", "materialID": "al-6061", "shape": "block", "quantity": 1,
                                                   "isRemnant": False, "location": "", "notes": "", "supplier": ""}
bars = [(150, 80, 20), (150, 40, 20)]
d["stock"] = []
for x, y, z in bars:
    s = dict(base, id=str(uuid.uuid4()).upper(), sizeX=x, sizeY=y, sizeZ=z, materialID="al-6061", finish="sawn",
             notes="regression")
    d["stock"].append(s)
json.dump(d, open(sys.argv[2], "w"))
PY
PENDANT=$ROOT/resources/samples/pendant.step
PLAQUE=$ROOT/resources/samples/plaque.step
typeset -A SCRIPTS
SCRIPTS[A]="import $PENDANT; wait 2; scale 0.8; stock 1; wait 1; holding clampKit"
SCRIPTS[B]="import $PLAQUE; wait 2; stock 0; wait 1; axes 2 0 1; holding bedOnly"
SCRIPTS[C]="import $PENDANT; wait 2; stock 0; wait 1; axes 1 0 2; holding prepThenKit"
SCRIPTS[D]="import $PENDANT; wait 2; stock 0; wait 1; scale 1.6; axes 1 0 2; holding shoulders"
SCRIPTS[E]="example watch_bridge; wait 2; holding x"
SCRIPTS[F]="example signet_pendant; wait 2; holding x"
SCRIPTS[G]="example pocket_rule; wait 2; holding x"
SCRIPTS[H]="example motor_mount; wait 2; holding x"
# The holding path each run must end up on (A–D, as `holding` prints it).
typeset -A PATH_OF
PATH_OF=(A A B B C C D D E A F A G B H D)
fail=0
for k in A B C D E F G H; do
  log=$OUT/$k.log
  t0=$(date +%s)
  COASTLINE_INVENTORY=$OUT/inv.json COASTLINE_SCRIPT="${SCRIPTS[$k]}; suggest; generate; collisions 15; crproj $OUT/$k.crproj; quit" "$APP" > $log 2>&1
  t1=$(date +%s)
  current=$(grep -E "^holding ${PATH_OF[$k]} .*current true" $log | head -1)
  gen=$(grep -E "^generate status=Toolpaths ready" $log | head -1)
  bad=$(grep -E "^program .* passed=false" $log | wc -l | tr -d ' ')
  progs=$(grep -cE "^program " $log)
  col=$(grep -E "^collisions" $log | tail -1)
  ok=1
  [[ -n $current ]] || { ok=0; echo "  $k: path $k wasn't chosen"; }
  [[ -n $gen ]] || { ok=0; echo "  $k: generation didn't finish: $(grep '^generate' $log | head -1)"; }
  [[ $bad == 0 && $progs -gt 0 ]] || { ok=0; echo "  $k: $bad of $progs programs failed their checks"; }
  [[ -f $OUT/$k.crproj ]] || { ok=0; echo "  $k: no .crproj"; }
  [[ $col == "collisions []"* && $col != *"machine tris -1"* ]] || { ok=0; echo "  $k: $col"; }
  if (( ok )); then echo "✓ $k  $progs programs, $((t1 - t0)) s"; else echo "✗ $k  (log: $log)"; fail=1; fi
done
echo "logs and projects: $OUT"
exit $fail
