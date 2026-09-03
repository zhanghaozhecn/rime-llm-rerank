cmake_minimum_required(VERSION 3.16)
project(rime_llm LANGUAGES C CXX)

set(LLAMA_ROOT "D:/llama.cpp-mirror" CACHE PATH "llama.cpp mirror root")

# Lua 5.4 source (embedded, in lua/ subdirectory)
file(GLOB LUA_SRCS "${CMAKE_CURRENT_SOURCE_DIR}/lua/l*.c")
list(FILTER LUA_SRCS EXCLUDE REGEX "lua\\.c$")
list(FILTER LUA_SRCS EXCLUDE REGEX "luac\\.c$")

add_library(rime_llm SHARED rime_llm.cpp ${LUA_SRCS})

target_include_directories(rime_llm PRIVATE
    "${LLAMA_ROOT}/include"
    "${LLAMA_ROOT}/ggml/include"
    "${LLAMA_ROOT}/common"
    "${CMAKE_CURRENT_SOURCE_DIR}/lua"
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
    # Post-build: copy DLL to cpp/user/
    add_custom_command(TARGET rime_llm POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:rime_llm>"
            "${CMAKE_SOURCE_DIR}/../user/rime_llm.dll"
    )

    # Thread count sweep benchmark (用户 cpu_cores 实测工具；重排效果研究评测器
    # sim_rerank/test_core/bench_sweep2/bench_single_char 已迁研究库
    # D:\llm-rerank-research\cpp\，2026-09-02)
    add_executable(bench_thr bench_threads.cpp)
    target_include_directories(bench_thr PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_thr PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_thr PRIVATE /O2 /arch:AVX2 /utf-8 /std:c++17)

    # GPU production DLL (CUDA backend, same layered algorithm as CPU)
    add_library(rime_llm_cuda SHARED rime_llm_cuda.cpp ${LUA_SRCS})
    target_include_directories(rime_llm_cuda PRIVATE
        "${LLAMA_ROOT}/include" "${LLAMA_ROOT}/ggml/include" "${LLAMA_ROOT}/common" "${CMAKE_CURRENT_SOURCE_DIR}/lua" "${CMAKE_CURRENT_SOURCE_DIR}")
    target_compile_definitions(rime_llm_cuda PRIVATE LUA_USE_WINDOWS)
    target_link_libraries(rime_llm_cuda PRIVATE
        "${LLAMA_CUDA_ROOT}/src/llama.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-base.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cpu.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cuda/ggml-cuda.lib")
    target_compile_options(rime_llm_cuda PRIVATE /O2 /arch:AVX2 /utf-8)
    set_target_properties(rime_llm_cuda PROPERTIES SUFFIX ".dll" PREFIX "")
    add_custom_command(TARGET rime_llm_cuda POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:rime_llm_cuda>"
            "${CMAKE_SOURCE_DIR}/../user/rime_llm_cuda.dll"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${LLAMA_CUDA_ROOT}/bin/ggml.dll"
            "$<TARGET_FILE_DIR:rime_llm_cuda>/ggml.dll"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${LLAMA_CUDA_ROOT}/bin/ggml-base.dll"
            "$<TARGET_FILE_DIR:rime_llm_cuda>/ggml-base.dll"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${LLAMA_CUDA_ROOT}/bin/ggml-cpu.dll"
            "$<TARGET_FILE_DIR:rime_llm_cuda>/ggml-cpu.dll"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${LLAMA_CUDA_ROOT}/bin/ggml-cuda.dll"
            "$<TARGET_FILE_DIR:rime_llm_cuda>/ggml-cuda.dll"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${LLAMA_CUDA_ROOT}/bin/llama.dll"
            "$<TARGET_FILE_DIR:rime_llm_cuda>/llama.dll")
endif()
