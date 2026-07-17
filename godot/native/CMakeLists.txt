cmake_minimum_required(VERSION 3.20)
project(orrery_native CXX)

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
# Force full optimization on the kernel regardless of build type — the whole
# point of the prototype is to measure the OPTIMIZED native ceiling.
target_compile_options(orrery_native PRIVATE -O3)
# Statically fold the MinGW runtime (libgcc/libstdc++/winpthread) INTO the dll
# so it has no external MinGW deps — otherwise Godot's loader hits Error 126.
target_link_options(orrery_native PRIVATE -static-libgcc -static-libstdc++ -static)

set_target_properties(orrery_native PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "orrery_native"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
)
