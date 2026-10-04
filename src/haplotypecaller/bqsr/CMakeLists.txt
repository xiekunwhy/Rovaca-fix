set(PackName bqsr)
set(PackSrc
    bqsr_read_covarivates.cpp
    bqsr_read_transformer.cpp
    apply_bqsr_utils.cpp
)

add_library(
    ${PackName}
    ${ROVACA_LIB_TYPE}
    ${PackSrc}
)

target_link_libraries(
    ${PackName}
    PUBLIC
)

target_include_directories(
    ${PackName}
    PUBLIC
    ..
    ../common/
    ../../IOStream/
    ../../rovaca_logger
    ../common/utils/
    ${Boost_INCLUDE_DIRS}
    ${SPDLOG_INCLUDE_DIR}
    ${HTSLIB_INCLUDE_DIR})
    
    install(TARGETS ${PackName} LIBRARY DESTINATION lib ARCHIVE DESTINATION lib RUNTIME DESTINATION bin)