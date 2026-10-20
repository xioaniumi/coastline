#!/bin/zsh
# Makes resources/examples/<id>.coastline: each example part planned with Find the Best Plan's
# middle option (`useplan mid`: Balanced, using tools you don't own when that's better),
# generated and saved with its toolpaths, so it opens ready on any Mac without generating.
#
#   scripts/make-example-projects.sh [inventory.json] [example ids…]
#
# Uses a COPY of the inventory (default: yours), never the real file. Build the app first
# (scripts/build-app.sh).
set -u
ROOT=${0:A:h:h}
APP=$ROOT/Coastline/.build/debug/Coastline
[[ -x $APP ]] || { echo "build the app first (scripts/build-app.sh)"; exit 1; }
INV=${1:-$HOME/Library/Application Support/Coastline/Inventory.json}
shift $(( $# > 0 ? 1 : 0 ))
OUT=$(mktemp -d /tmp/coastline-examples.XXXX)
# One side or two, fixed in the project (the analysis' choice for each part).
typeset -A SIDES
SIDES=(watch_bridge off signet_pendant on pocket_rule off motor_mount off first_cut off)
if (( $# )); then ids=($@); else ids=(watch_bridge signet_pendant pocket_rule motor_mount first_cut); fi
# Which of Find the Best Plan's options (useplan): the first cut uses only tools you have.
typeset -A PLAN
PLAN=(watch_bridge mid signet_pendant mid pocket_rule mid motor_mount mid first_cut owned)
fail=0
for id in $ids; do
  cp "$INV" $OUT/inv_$id.json
  project=$ROOT/resources/examples/$id.coastline
  rm -f $project  # otherwise `example` opens the saved one
  log=$OUT/$id.log
  COASTLINE_INVENTORY=$OUT/inv_$id.json \
  COASTLINE_SCRIPT="size 1440x900; example $id; wait 3; twosided ${SIDES[$id]}; wait 2; plans; useplan ${PLAN[$id]}; generate; saveproject $project; quit" \
    "$APP" > $log 2>&1
  gen=$(grep -E "^generate status=Toolpaths ready" $log | head -1)
  bad=$(grep -cE "^program .* passed=false" $log)
  plan=$(grep -E "^using plan" $log | head -1)
  if [[ -n $gen && $bad == 0 && -f $project ]]; then
    echo "✓ $id  ${plan#using plan }  ·  ${gen#*· }  ·  $(du -h $project | cut -f1)"
  else
    echo "✗ $id  (log: $log)"; fail=1
  fi
done
exit $fail
