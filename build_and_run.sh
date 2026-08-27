#!/bin/bash
#
# Manual build script for the Case 3 POC on any macOS with Apple Silicon.
# Run this from the poc3_harness/ directory.
#
# Prerequisites:
#   - macOS with Apple Silicon (M1+)
#   - Xcode with Metal SDK installed
#   - MaterialX source cloned somewhere
#
# Usage:
#   MATERIALX_SRC=/path/to/MaterialX ./build_and_run.sh
#

set -euo pipefail

MATERIALX_SRC="${MATERIALX_SRC:-../../}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NPROC="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "=== Step 1: Verify Metal device ==="
swift -e '
import Metal
guard let d = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
print("Metal device: \(d.name)")
'

echo ""
echo "=== Step 2: Build MaterialX with ASan ==="
cd "$MATERIALX_SRC"
mkdir -p build_asan && cd build_asan
cmake .. \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_CXX_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g" \
    -DCMAKE_C_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g" \
    -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address" \
    -DCMAKE_SHARED_LINKER_FLAGS="-fsanitize=address" \
    -DMATERIALX_BUILD_RENDER=ON \
    -DMATERIALX_BUILD_RENDER_PLATFORMS=ON \
    -DMATERIALX_BUILD_GEN_MSL=ON \
    -DMATERIALX_BUILD_TESTS=OFF \
    -DMATERIALX_BUILD_PYTHON=OFF \
    -DCMAKE_INSTALL_PREFIX="$(pwd)/installed"
cmake --build . -j"$NPROC"
cmake --install .

MTX_INSTALL="$(pwd)/installed"
cd "$SCRIPT_DIR"

echo ""
echo "=== Step 3: Build POC harness ==="
mkdir -p build && cd build
cmake .. \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DMaterialX_DIR="$MTX_INSTALL/lib/cmake/MaterialX" \
    -DENABLE_ASAN=ON
cmake --build . -j"$NPROC"

cp ../texcoord_vec3.gltf .

echo ""
echo "=== Step 4: Run POC ==="
export MATERIALX_SEARCH_PATH="$MATERIALX_SRC"
export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1:print_stacktrace=1"

echo "Running: ./msl_bindattr_poc texcoord_vec3.gltf"
echo "Expected: ASan heap-buffer-overflow in MslProgram::bindAttribute"
echo ""
./msl_bindattr_poc texcoord_vec3.gltf 2>&1 | tee asan_crash.log || true

echo ""
if grep -q "heap-buffer-overflow" asan_crash.log; then
    echo "=== CONFIRMED: heap-buffer-overflow detected ==="
    echo "Submit asan_crash.log and texcoord_vec3.gltf as the POC."
else
    echo "=== Check asan_crash.log for details ==="
fi
