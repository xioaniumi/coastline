#!/bin/zsh
# Builds coastline_engine/_native (pybind11 C++ kernels) with the CLT clang.
# Usage: native/build.sh   (run from engine/ or anywhere)
set -euo pipefail
ENGINE="${0:A:h:h}"
cd "$ENGINE"
export PATH="$HOME/.local/bin:$PATH"
PY="$ENGINE/.venv/bin/python"
TP=native/third_party
SUFFIX=$("$PY" -c "import sysconfig;print(sysconfig.get_config_var('EXT_SUFFIX'))")
PYINC=$("$PY" -c "import sysconfig;print(sysconfig.get_paths()['include'])")
PBINC=$("$PY" -c "import pybind11;print(pybind11.get_include())")
OUT="coastline_engine/_native$SUFFIX"
mkdir -p build
SRCS=(native/src/module.cpp $TP/freecad_adaptive/Adaptive.cpp $TP/freecad_adaptive/clipper.cpp $TP/clipper2/src/*.cpp)
clang++ -std=c++20 -O2 -fPIC -shared -undefined dynamic_lookup -arch arm64 \
  -fvisibility=hidden -w -DUSINGZ \
  -I"$PYINC" -I"$PBINC" -I$TP/freecad_adaptive -I$TP/clipper2/include \
  "${SRCS[@]}" -o "$OUT"
echo "built $OUT"
