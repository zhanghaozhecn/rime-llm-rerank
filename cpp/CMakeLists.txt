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

# Latency benchmark (standalone exe, same scoring algorithm as DLL)
add_executable(bench_latency bench_latency.cpp)
target_include_directories(bench_latency PRIVATE
    "${LLAMA_ROOT}/include"
    "${LLAMA_ROOT}/ggml/include"
    "${LLAMA_ROOT}/common"
)
target_link_libraries(bench_latency PRIVATE
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
    target_compile_options(bench_latency PRIVATE /O2 /arch:AVX2 /utf-8)

    # KV cache copy test
    add_executable(bench_kv bench_kv.cpp)
    target_include_directories(bench_kv PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_kv PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_kv PRIVATE /O2 /arch:AVX2 /utf-8)

    # Cand sweep benchmark (old ctx×N vs new KV copy)
    add_executable(bench_sweep bench_sweep.cpp)
    target_include_directories(bench_sweep PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_sweep PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_sweep PRIVATE /O2 /arch:AVX2 /utf-8)

    # KV copy correctness verification
    add_executable(bench_verify bench_verify.cpp)
    target_include_directories(bench_verify PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_verify PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_verify PRIVATE /O2 /arch:AVX2 /utf-8)

    # Wiki corpus evaluation
    add_executable(bench_wiki bench_wiki.cpp)
    target_include_directories(bench_wiki PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_wiki PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_wiki PRIVATE /O2 /arch:AVX2 /utf-8)

    # CE comparison: gold single-seq vs KV copy
    add_executable(bench_cecmp bench_cecmp.cpp)
    target_include_directories(bench_cecmp PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_cecmp PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_cecmp PRIVATE /O2 /arch:AVX2 /utf-8)

    # Accuracy comparison: two-step vs KV copy
    add_executable(bench_acc bench_acc.cpp)
    target_include_directories(bench_acc PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_acc PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_acc PRIVATE /O2 /arch:AVX2 /utf-8)

    # Real encoding evaluation (dict code-mates + corpus context)
    add_executable(bench_enc bench_enc.cpp)
    target_include_directories(bench_enc PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_enc PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_enc PRIVATE /O2 /arch:AVX2 /utf-8 /std:c++17)

    # Automated core tests (CE correctness + accuracy regression)
    add_executable(test_core test_core.cpp)
    target_include_directories(test_core PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(test_core PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(test_core PRIVATE /O2 /arch:AVX2 /utf-8 /std:c++17)

    # Latency benchmark
    add_executable(bench_lat bench_lat.cpp)
    target_include_directories(bench_lat PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_lat PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_lat PRIVATE /O2 /arch:AVX2 /utf-8)

    # Layered multi-seq benchmark (ctx once + per-layer parallel decode)
    add_executable(bench_hyb bench_hyb.cpp)
    target_include_directories(bench_hyb PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_hyb PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_hyb PRIVATE /O2 /arch:AVX2 /utf-8 /std:c++17)

    # Thread count + method benchmark
    add_executable(bench_thr bench_thr.cpp)
    target_include_directories(bench_thr PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_thr PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_thr PRIVATE /O2 /arch:AVX2 /utf-8 /std:c++17)

    # Logits frame debug
    add_executable(bench_dbg bench_dbg.cpp)
    target_include_directories(bench_dbg PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_dbg PRIVATE
        llama_cpu ggml_cpu ggml_base ggml_cpu_impl
    )
    target_compile_options(bench_dbg PRIVATE /O2 /arch:AVX2 /utf-8)

    # GPU accuracy sweep (links against CUDA build of llama.cpp)
    set(LLAMA_CUDA_ROOT "D:/llama.cpp-mirror/build-cuda" CACHE PATH "llama.cpp CUDA build root")
    add_executable(bench_gpu bench_gpu.cpp)
    target_include_directories(bench_gpu PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_gpu PRIVATE
        "${LLAMA_CUDA_ROOT}/src/llama.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-base.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cpu.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cuda/ggml-cuda.lib"
    )
    target_compile_options(bench_gpu PRIVATE /O2 /arch:AVX2 /utf-8 /std:c++17)
    # Post-build: copy CUDA DLLs to output dir
    add_custom_command(TARGET bench_gpu POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${LLAMA_CUDA_ROOT}/bin/ggml.dll"
            "$<TARGET_FILE_DIR:bench_gpu>/ggml.dll"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${LLAMA_CUDA_ROOT}/bin/ggml-base.dll"
            "$<TARGET_FILE_DIR:bench_gpu>/ggml-base.dll"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${LLAMA_CUDA_ROOT}/bin/ggml-cpu.dll"
            "$<TARGET_FILE_DIR:bench_gpu>/ggml-cpu.dll"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${LLAMA_CUDA_ROOT}/bin/ggml-cuda.dll"
            "$<TARGET_FILE_DIR:bench_gpu>/ggml-cuda.dll"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${LLAMA_CUDA_ROOT}/bin/llama.dll"
            "$<TARGET_FILE_DIR:bench_gpu>/llama.dll"
    )

    # Mega-batch GPU sweep (cross-sample batching for max throughput)
    add_executable(bench_mega bench_mega.cpp)
    target_include_directories(bench_mega PRIVATE
        "${LLAMA_ROOT}/include"
        "${LLAMA_ROOT}/ggml/include"
        "${LLAMA_ROOT}/common"
    )
    target_link_libraries(bench_mega PRIVATE
        "${LLAMA_CUDA_ROOT}/src/llama.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-base.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cpu.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cuda/ggml-cuda.lib"
    )
    target_compile_options(bench_mega PRIVATE /O2 /arch:AVX2 /utf-8 /std:c++17)
endif()

    # GPU 双因素扫参 (tok × cand, 20000 samples)
    add_executable(bench_sweep2 bench_sweep2.cpp)
    target_include_directories(bench_sweep2 PRIVATE
        "${LLAMA_ROOT}/include" "${LLAMA_ROOT}/ggml/include" "${LLAMA_ROOT}/common")
    target_link_libraries(bench_sweep2 PRIVATE
        "${LLAMA_CUDA_ROOT}/src/llama.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-base.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cpu.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cuda/ggml-cuda.lib")
    target_compile_options(bench_sweep2 PRIVATE /O2 /arch:AVX2 /utf-8 /std:c++17)

    # GPU layered + cross-sample batch sweep
    add_executable(bench_gpu2 bench_gpu2.cpp)
    target_include_directories(bench_gpu2 PRIVATE
        "${LLAMA_ROOT}/include" "${LLAMA_ROOT}/ggml/include" "${LLAMA_ROOT}/common")
    target_link_libraries(bench_gpu2 PRIVATE
        "${LLAMA_CUDA_ROOT}/src/llama.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-base.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cpu.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cuda/ggml-cuda.lib")
    target_compile_options(bench_gpu2 PRIVATE /O2 /arch:AVX2 /utf-8)
target_compile_features(bench_gpu2 PRIVATE cxx_std_17)

    # GPU latency stability benchmark (same input, repeat N times)
    add_executable(bench_stable bench_stable.cpp)
    target_include_directories(bench_stable PRIVATE
        "${LLAMA_ROOT}/include" "${LLAMA_ROOT}/ggml/include" "${LLAMA_ROOT}/common")
    target_link_libraries(bench_stable PRIVATE
        "${LLAMA_CUDA_ROOT}/src/llama.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-base.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cpu.lib"
        "${LLAMA_CUDA_ROOT}/ggml/src/ggml-cuda/ggml-cuda.lib")
    target_compile_options(bench_stable PRIVATE /O2 /arch:AVX2 /utf-8 /std:c++17)

    # GPU production DLL (CUDA backend, same layered algorithm as CPU)
    add_library(rime_llm_cuda SHARED rime_llm_cuda.cpp ${LUA_SRCS})
    target_include_directories(rime_llm_cuda PRIVATE
        "${LLAMA_ROOT}/include" "${LLAMA_ROOT}/ggml/include" "${LLAMA_ROOT}/common" "${CMAKE_CURRENT_SOURCE_DIR}")
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
