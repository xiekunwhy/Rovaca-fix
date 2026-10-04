set(PACK_NAME base)
set(PACK_SRC lib/mempool/mem_pool_fast.c lib/mempool/mem_pool_auto_enlarge.c lib/mempool/ring_mem_pool.c lib/sw_avx/sw_avx2.c
             lib/sw_avx/sw_avx.c lib/ro_sw/sw_cigar.c lib/ro_sw/ro_sw.c)
set(PACK_INCLUDE_DIR include ${HTSLIB_INCLUDE_DIR})
set(PACK_LINK_DIR)
set(PACK_LINK_LIB pthread m)

# ============================================================================
# ro_sw: 使用 object library 分别编译 AVX2 和 AVX512 版本
# ============================================================================
# AVX2 版本的 object library
add_library(ro_sw_avx2_obj OBJECT
    lib/ro_sw/avx2_sw_core.c
)
target_compile_options(ro_sw_avx2_obj PRIVATE -mavx -mavx2 -fgnu89-inline)
target_include_directories(ro_sw_avx2_obj PRIVATE ${PACK_INCLUDE_DIR})

# AVX512 版本的 object library
add_library(ro_sw_avx512_obj OBJECT
    lib/ro_sw/avx512_sw_core.c
)
target_compile_options(ro_sw_avx512_obj PRIVATE -mavx -mavx2 -mavx512f -mavx512dq -mavx512bw -mavx512vl -fgnu89-inline)
target_include_directories(ro_sw_avx512_obj PRIVATE ${PACK_INCLUDE_DIR})

add_library(${PACK_NAME} ${ROVACA_LIB_TYPE} ${PACK_SRC} $<TARGET_OBJECTS:ro_sw_avx2_obj> $<TARGET_OBJECTS:ro_sw_avx512_obj>)
target_compile_options(${PACK_NAME} PRIVATE -mavx -mavx2 -fgnu89-inline)
target_include_directories(${PACK_NAME} PUBLIC ${PACK_INCLUDE_DIR})
target_link_directories(${PACK_NAME} PUBLIC ${PACK_LINK_DIR})
target_link_libraries(${PACK_NAME} PUBLIC ${PACK_LINK_LIB})

if(ENABLE_ASAN)
    include(asan)
    enable_sanitizer(${PACK_NAME})
endif()

if(ENABLE_GCOV)
    include(gcov)
    enable_gcov(${PACK_NAME})
endif()

install(TARGETS ${PACK_NAME} LIBRARY DESTINATION lib ARCHIVE DESTINATION lib RUNTIME DESTINATION bin)

# 添加测试目录
add_subdirectory(test)
