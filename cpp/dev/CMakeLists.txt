cmake_minimum_required(VERSION 3.16)
project(rime_llm LANGUAGES C CXX)

set(LLAMA_ROOT "D:/llama.cpp-mirror" CACHE PATH "llama.cpp mirror root")

# Lua 5.4 source (embedded)
file(GLOB LUA_SRCS "${CMAKE_CURRENT_SOURCE_DIR}/l*.c")
list(FILTER LUA_SRCS EXCLUDE REGEX "lua\\.c$")
list(FILTER LUA_SRCS EXCLUDE REGEX "luac\\.c$")

add_library(rime_llm SHARED rime_llm.cpp ${LUA_SRCS})

target_include_directories(rime_llm PRIVATE
    "${LLAMA_ROOT}/include"
    "${LLAMA_ROOT}/ggml/include"
    "${LLAMA_ROOT}/common"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

target_compile_definitions(rime_llm PRIVATE LUA_USE_WINDOWS)

# Link llama.cpp static libs
add_library(llama_cpu STATIC IMPORTED)
set_target_properties(llama_cpu PROPERTIES
    IMPORTED_LOCATION "${LLAMA_ROOT}/build/src/Release/llama.lib"
)
add_library(ggml_cpu STATIC IMPORTED)
set_target_properties(ggml_cpu PROPERTIES
    IMPORTED_LOCATION "${LLAMA_ROOT}/build/ggml/src/Release/ggml.lib"
)
add_library(ggml_base STATIC IMPORTED)
set_target_properties(ggml_base PROPERTIES
    IMPORTED_LOCATION "${LLAMA_ROOT}/build/ggml/src/Release/ggml-base.lib"
)
add_library(ggml_cpu_impl STATIC IMPORTED)
set_target_properties(ggml_cpu_impl PROPERTIES
    IMPORTED_LOCATION "${LLAMA_ROOT}/build/ggml/src/Release/ggml-cpu.lib"
)

target_link_libraries(rime_llm PRIVATE
    llama_cpu ggml_cpu ggml_base ggml_cpu_impl
)

if(MSVC)
    target_compile_options(rime_llm PRIVATE /O2 /arch:AVX2 /utf-8)
    target_link_options(rime_llm PRIVATE /OPT:REF /OPT:ICF)
    set_target_properties(rime_llm PROPERTIES SUFFIX ".dll" PREFIX "")
endif()
