cmake_minimum_required(VERSION 3.20)
project(orrery_native CXX)

# Per-ABI output lib name (desktop uses the default; Android passes an
# arch-tagged name so ABIs don't collide in bin/).
set(ORRERY_OUTPUT_NAME "orrery_native" CACHE STRING "output library name")

# godot-cpp: template_debug tags for editor-load compatibility; optimization
# comes from CMAKE_BUILD_TYPE=Release (set on the configure line).
set(GODOTCPP_TARGET template_debug CACHE STRING "" FORCE)
add_subdirectory(godot-cpp)

add_library(orrery_native SHARED
    src/nbody_core.cpp
    src/nbody_native.cpp
    src/register_types.cpp
)
target_link_libraries(orrery_native PRIVATE godot::cpp)
# Force full optimization on the kernel regardless of build type.
target_compile_options(orrery_native PRIVATE -O3)
# Windows/MinGW only: fold the MinGW runtime into the dll so it is
# self-contained (else Godot's loader hits Error 126). The NDK/clang build
# uses a static libc++ instead (ANDROID_STL=c++_static on the configure line).
if (WIN32)
    target_link_options(orrery_native PRIVATE -static-libgcc -static-libstdc++ -static)
endif()

set_target_properties(orrery_native PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "${ORRERY_OUTPUT_NAME}"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
)
