cmake_minimum_required(VERSION 3.16)
project(rime_llm LANGUAGES C CXX)

# —— llama.cpp 根目录 ——
set(LLAMA_ROOT "D:/llama.cpp-mirror" CACHE PATH "llama.cpp root")

# —— Lua headers ——
# RIME (小狼毫) 使用 Lua 5.4。如果已安装，指定 LUA_DIR
find_path(LUA_INCLUDE_DIR lua.h
    HINTS "${CMAKE_CURRENT_SOURCE_DIR}"
          ${LUA_DIR}/include
          "C:/Program Files/Rime/weasel-0.17.4"
          "${LLAMA_ROOT}/lua"
    DOC "Path to lua.h"
)

if(NOT LUA_INCLUDE_DIR)
    message(FATAL_ERROR "lua.h not found. Set LUA_DIR to Lua 5.4 include path.")
endif()
message(STATUS "Lua include: ${LUA_INCLUDE_DIR}")

# —— llama.cpp static libs ——
set(LLAMA_BUILD_DIR "${LLAMA_ROOT}/build" CACHE PATH "llama.cpp build dir")

add_library(llama STATIC IMPORTED)
set_target_properties(llama PROPERTIES
    IMPORTED_LOCATION "${LLAMA_BUILD_DIR}/src/Release/llama.lib"
)

add_library(ggml STATIC IMPORTED)
set_target_properties(ggml PROPERTIES
    IMPORTED_LOCATION "${LLAMA_BUILD_DIR}/ggml/src/Release/ggml.lib"
)

add_library(ggml_base STATIC IMPORTED)
set_target_properties(ggml_base PROPERTIES
    IMPORTED_LOCATION "${LLAMA_BUILD_DIR}/ggml/src/Release/ggml-base.lib"
)

add_library(ggml_cpu STATIC IMPORTED)
set_target_properties(ggml_cpu PROPERTIES
    IMPORTED_LOCATION "${LLAMA_BUILD_DIR}/ggml/src/Release/ggml-cpu.lib"
)

# —— Lua 5.4 内嵌编译 ——
file(GLOB LUA_SRCS "${CMAKE_CURRENT_SOURCE_DIR}/l*.c")
list(FILTER LUA_SRCS EXCLUDE REGEX "lua\\.c$")
list(FILTER LUA_SRCS EXCLUDE REGEX "luac\\.c$")

# —— Plugin DLL ——
add_library(rime_llm SHARED rime_llm.cpp ${LUA_SRCS})
target_include_directories(rime_llm PRIVATE
    "${LLAMA_ROOT}/include"
    "${LLAMA_ROOT}/ggml/include"
    "${LLAMA_ROOT}/common"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_definitions(rime_llm PRIVATE LUA_USE_WINDOWS)
target_link_libraries(rime_llm PRIVATE llama ggml ggml_base ggml_cpu)

# —— Compiler flags ——
if(MSVC)
    target_compile_options(rime_llm PRIVATE /O2 /arch:AVX2 /utf-8)
    target_link_options(rime_llm PRIVATE /OPT:REF /OPT:ICF)
    set_target_properties(rime_llm PROPERTIES
        SUFFIX ".dll"
        PREFIX ""
    )
endif()

install(TARGETS rime_llm DESTINATION .)
