cmake_minimum_required(VERSION 3.16)
project(msl_bindattr_poc LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)

# ---- Find MaterialX (built from source or installed) ----
# Option A: Point to a local MaterialX build
# set(MaterialX_DIR "/path/to/MaterialX/build/installed/lib/cmake/MaterialX")

# Option B: If MaterialX is installed system-wide or CMAKE_PREFIX_PATH is set
find_package(MaterialX REQUIRED)

message(STATUS "Found MaterialX: ${MaterialX_DIR}")

# ---- POC executable ----
add_executable(msl_bindattr_poc msl_bindattr_harness.mm)

target_link_libraries(msl_bindattr_poc
    MaterialXCore
    MaterialXFormat
    MaterialXGenShader
    MaterialXGenMsl
    MaterialXRender
    MaterialXRenderMsl
    MaterialXRenderHw
    "-framework Metal"
    "-framework Foundation"
    "-framework CoreGraphics"
    "-framework AppKit"
    "-framework QuartzCore"
)

# Enable ASan
if(ENABLE_ASAN)
    target_compile_options(msl_bindattr_poc PRIVATE -fsanitize=address -fno-omit-frame-pointer -g -O1)
    target_link_options(msl_bindattr_poc PRIVATE -fsanitize=address)
endif()
