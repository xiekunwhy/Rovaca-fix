set(PACK_NAME pairhmm)
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,--no-as-needed")

# 基础源文件设置
set_property(SOURCE roDV_schedule.cpp APPEND_STRING PROPERTY COMPILE_FLAGS "-mavx -mavx2")

# ============================================================================
# roDV inter: 使用 object library 编译两次（参考 roDV 的方式）
# ============================================================================
# AVX2 版本的 object library
add_library(rodv_inter_avx2_obj OBJECT
    roDV_inter/pairhmm_inter.cpp
    roDV_inter/pairhmm_inter_api.cpp
)
target_compile_options(rodv_inter_avx2_obj PRIVATE -mavx -mavx2)
target_compile_definitions(rodv_inter_avx2_obj PRIVATE __AVX2__)
target_include_directories(rodv_inter_avx2_obj PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/roDV_common)

# AVX512 版本的 object library
add_library(rodv_inter_avx512_obj OBJECT
    roDV_inter/pairhmm_inter.cpp
    roDV_inter/pairhmm_inter_api.cpp
)
target_compile_options(rodv_inter_avx512_obj PRIVATE -mavx -mavx2 -mavx512f -mavx512dq -mavx512vl)
target_compile_definitions(rodv_inter_avx512_obj PRIVATE __AVX512F__)
target_include_directories(rodv_inter_avx512_obj PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/roDV_common)

# ============================================================================
# roDV intra: 使用 object library 编译两次（参考 roDV 的方式）
# ============================================================================
# AVX2 版本的 object library
add_library(rodv_intra_avx2_obj OBJECT
    roDV_intra/pairhmm_impl.cpp
    roDV_intra/pairhmm_api.cpp
)
target_compile_options(rodv_intra_avx2_obj PRIVATE -mavx -mavx2)
target_compile_definitions(rodv_intra_avx2_obj PRIVATE __AVX2__)
target_include_directories(rodv_intra_avx2_obj PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/roDV_common)

# AVX512 版本的 object library
add_library(rodv_intra_avx512_obj OBJECT
    roDV_intra/pairhmm_impl.cpp
    roDV_intra/pairhmm_api.cpp
)
target_compile_options(rodv_intra_avx512_obj PRIVATE -mavx -mavx2 -mavx512f -mavx512dq -mavx512vl)
target_compile_definitions(rodv_intra_avx512_obj PRIVATE __AVX512F__)
target_include_directories(rodv_intra_avx512_obj PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/roDV_common)

# ============================================================================
# 主库：包含所有源文件和 object library
# ============================================================================
# core 和 rovaca 的源文件已删除，只保留头文件（如需要）
# set(CORE_HEADERS core/avx.h core/avx_impl.h core/avx_type.h core/common.h core/const.h core/context.h)
# set(ROVACA_HEADERS rovaca/avx_512_float.h rovaca/common.h rovaca/context.h rovaca/internal.h)
set(RODV_COMMON_SRC roDV_common/common.h roDV_common/context.h roDV_common/cpu_features.h)
set(RODV_INTER_HEADERS roDV_inter/pairhmm_inter.h roDV_inter/pairhmm_inter_api.h roDV_inter/simd_traits.h roDV_inter/simd_traits_avx2.h roDV_inter/simd_traits_avx512.h)
set(RODV_INTRA_HEADERS roDV_intra/pairhmm_api.h roDV_intra/pairhmm_impl.h roDV_intra/simd_traits.h roDV_intra/simd_traits_avx2.h roDV_intra/simd_traits_avx512.h)
set(RODV_ADAPTER_SRC roDV_adapter/rovaca_pool_allocator.h)
set(RODV_SCHEDULE_SRC roDV_schedule.h roDV_schedule.cpp)
set(PACK_SRC ${RODV_COMMON_SRC} ${RODV_INTER_HEADERS} ${RODV_INTRA_HEADERS} ${RODV_ADAPTER_SRC} ${RODV_SCHEDULE_SRC} pairhmm_engine.cpp pairhmm_engine.h pairhmm_internal.cpp pairhmm_internal.h)

add_library(${PACK_NAME} ${ROVACA_LIB_TYPE} ${PACK_SRC})
target_sources(${PACK_NAME} PRIVATE
    $<TARGET_OBJECTS:rodv_inter_avx2_obj>
    $<TARGET_OBJECTS:rodv_inter_avx512_obj>
    $<TARGET_OBJECTS:rodv_intra_avx2_obj>
    $<TARGET_OBJECTS:rodv_intra_avx512_obj>
)
target_include_directories(${PACK_NAME} PRIVATE ${HTSLIB_INCLUDE_DIR} ../../rovaca_logger)
target_link_libraries(${PACK_NAME} PRIVATE logger)

install(TARGETS ${PACK_NAME} LIBRARY DESTINATION lib ARCHIVE DESTINATION lib RUNTIME DESTINATION bin)

# 添加测试子目录
if(ENABLE_GOOGLE_TEST)
    add_subdirectory(test)
endif()

IF(ENABLE_ASAN)
    include(asan)
    enable_sanitizer(${PACK_NAME})
endif()