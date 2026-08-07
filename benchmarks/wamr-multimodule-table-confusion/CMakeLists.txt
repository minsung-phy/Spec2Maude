cmake_minimum_required(VERSION 3.14)
project(wamr_multimodule_table_confusion C)

if(NOT DEFINED WAMR_ROOT_DIR)
  message(FATAL_ERROR "pass -DWAMR_ROOT_DIR=/path/to/wasm-micro-runtime")
endif()

set(WAMR_TEST_FAST_INTERP 0 CACHE STRING
  "Build the fast interpreter instead of the classic interpreter")
set(WAMR_TEST_GC 0 CACHE STRING
  "Enable WAMR's Wasm GC implementation")

set(WAMR_BUILD_PLATFORM "linux")
set(WAMR_BUILD_TARGET "X86_64")
set(WAMR_BUILD_INTERP 1)
set(WAMR_BUILD_FAST_INTERP ${WAMR_TEST_FAST_INTERP})
set(WAMR_BUILD_AOT 0)
set(WAMR_BUILD_JIT 0)
set(WAMR_BUILD_FAST_JIT 0)
set(WAMR_BUILD_SIMD 0)
set(WAMR_BUILD_GC ${WAMR_TEST_GC})
set(WAMR_BUILD_REF_TYPES 1)
set(WAMR_BUILD_MULTI_MODULE 1)
set(WAMR_BUILD_LIBC_BUILTIN 0)
set(WAMR_BUILD_LIBC_WASI 0)
set(WAMR_BUILD_THREAD_MGR 0)

include(${WAMR_ROOT_DIR}/build-scripts/runtime_lib.cmake)

add_library(vmlib STATIC ${WAMR_RUNTIME_LIB_SOURCE})
add_executable(wamr-table-confusion wamr_host.c)
target_include_directories(wamr-table-confusion PRIVATE
  ${WAMR_ROOT_DIR}/core/iwasm/include)
target_link_libraries(wamr-table-confusion PRIVATE vmlib pthread m dl)
