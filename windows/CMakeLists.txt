# VietTelex for Windows — top-level build.
#
#   Windows (MSVC, per architecture):
#     cmake -S windows -B build-x64 -A x64 && cmake --build build-x64 --config Release
#     cmake -S windows -B build-arm64 -A ARM64 ...   cmake -S windows -B build-x86 -A Win32 ...
#   Any OS (portable core + unit tests only):
#     cmake -S windows -B build && cmake --build build && ctest --test-dir build
#
# Targets: viettelex_engine (windows/engine), vtx_ime_core, vtx_ime_tests,
#          VietTelexTIP.dll (Windows), VietTelex.exe (Windows).
cmake_minimum_required(VERSION 3.20)
project(VietTelex LANGUAGES C CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
# Static CRT everywhere: the TIP is loaded into every process and must not depend on
# a VC++ redistributable being installed.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
# Size (non-MSVC: llvm-mingw cross builds, host builds): one section per function / data
# item in EVERY library (engine, cores), so the binaries' -Wl,--gc-sections drops what they
# do not call — VietTelexSetupHelper.exe pulls one JSON helper from the IME core, not the
# whole object. MSVC gets the same from /Gy /Gw + /OPT:REF on its targets.
if(NOT MSVC)
  add_compile_options(-ffunction-sections -fdata-sections)
endif()
# ThinLTO for the llvm-mingw cross build (clang + lld; scripts/cross-build.sh). Checked for
# x86 (--kill-at exports), x64 and ARM64.
option(VTX_THIN_LTO "ThinLTO for clang/lld Windows (MinGW) builds" ON)
if(VTX_THIN_LTO AND WIN32 AND MINGW AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-flto=thin)
  add_link_options(-flto=thin)
endif()

# Release version (x.y.z) stamped into both binaries' version resources and the updater.
set(VTX_VERSION "" CACHE STRING "Release version x.y.z (empty = ime/version.h default)")
if(VTX_VERSION)
  if(NOT VTX_VERSION MATCHES "^([0-9]+)\\.([0-9]+)\\.([0-9]+)$")
    message(FATAL_ERROR "VTX_VERSION must be x.y.z, got '${VTX_VERSION}'")
  endif()
  add_compile_definitions(VTX_VER_MAJOR=${CMAKE_MATCH_1} VTX_VER_MINOR=${CMAKE_MATCH_2}
                          VTX_VER_PATCH=${CMAKE_MATCH_3} VTX_VER_BUILD=0)
  set(CMAKE_RC_FLAGS "${CMAKE_RC_FLAGS} -DVTX_VER_MAJOR=${CMAKE_MATCH_1} -DVTX_VER_MINOR=${CMAKE_MATCH_2} -DVTX_VER_PATCH=${CMAKE_MATCH_3} -DVTX_VER_BUILD=0")
endif()

enable_testing()
add_subdirectory(engine)
add_subdirectory(ime)
add_subdirectory(app)   # portable core + tests everywhere; VietTelex.exe on Windows
