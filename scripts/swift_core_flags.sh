#!/bin/bash
# Source after resolving CORE_BIN. Standalone swiftc test executables need the
# transitive Clang module maps that SwiftPM normally supplies automatically.
GLACIER_CORE_FLAGS=(
  -I "$CORE_BIN" -I "$CORE_BIN/Modules"
  -I "$PWD/.build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include"
  -I "$PWD/.build/checkouts/FluidAudio/Sources/FastClusterWrapper/include"
  -L "$CORE_BIN" -lGlacierCore -lc++
)
