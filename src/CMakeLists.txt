include(version)
generate_version()

set(ROVACA_USE_BUNDLED_BOOST OFF)
set(BOOST_PROGRAM_OPTIONS_INSTALL_LIB "")
if(ROVACA_STATIC)
    set(ROVACA_BUNDLED_BOOST_LIB "${CMAKE_SOURCE_DIR}/third_lib/static-deps/lib/libboost_program_options.a")
else()
    set(ROVACA_BUNDLED_BOOST_LIB "${CMAKE_SOURCE_DIR}/libboost_program_options.so.1.83.0")
endif()

if(NOT ROVACA_STATIC)
    find_package(Boost ${MIN_BOOST_VERSION} QUIET COMPONENTS program_options)
endif()
if(NOT ROVACA_STATIC AND Boost_FOUND AND Boost_PROGRAM_OPTIONS_FOUND)
    message(STATUS "* * * * * * * * * * * system boost version: ${Boost_LIB_VERSION} * * * * * * * * * * *")
else()
    if(EXISTS "${ROVACA_BUNDLED_BOOST_LIB}")
        set(ROVACA_USE_BUNDLED_BOOST ON)
        set(BOOST_PROGRAM_OPTIONS_INSTALL_LIB "${ROVACA_BUNDLED_BOOST_LIB}")
        get_filename_component(ROVACA_BUNDLED_BOOST_DIR "${ROVACA_BUNDLED_BOOST_LIB}" DIRECTORY)

        set(Boost_LIBRARY_DIRS "${ROVACA_BUNDLED_BOOST_DIR}")
        set(Boost_LIBRARIES "${ROVACA_BUNDLED_BOOST_LIB}")
        set(Boost_PROGRAM_OPTIONS_LIBRARY "${ROVACA_BUNDLED_BOOST_LIB}")

        if(NOT Boost_INCLUDE_DIRS)
            find_path(ROVACA_BOOST_INCLUDE_DIR
                NAMES boost/program_options.hpp
                PATHS /usr/include /usr/local/include ${CMAKE_SOURCE_DIR}/third_lib/boost/include ${CMAKE_SOURCE_DIR}/third_lib/static-deps/include)
            if(ROVACA_BOOST_INCLUDE_DIR)
                set(Boost_INCLUDE_DIRS "${ROVACA_BOOST_INCLUDE_DIR}")
            else()
                message(FATAL_ERROR "Boost headers not found. Please install boost headers or provide third_lib/boost/include")
            endif()
        endif()

        message(WARNING "System boost program_options not found; using bundled ${ROVACA_BUNDLED_BOOST_LIB}")
    else()
        message(FATAL_ERROR "System boost program_options not found and bundled ${ROVACA_BUNDLED_BOOST_LIB} is missing")
    endif()
endif()

add_subdirectory(common)
add_subdirectory(IOStream)
add_subdirectory(rovaca_logger)
add_subdirectory(haplotypecaller)

set(PACK_NAME main)
set(PACK_SRC rovaca_main.h rovaca_main.cpp)
set(PACK_INCLUDE_DIR IOStream ${Boost_INCLUDE_DIRS} ${HTSLIB_INCLUDE_DIR} ${SPDLOG_INCLUDE_DIR} rovaca_logger)
set(PACK_LINK_DIR ${CMAKE_LIBRARY_OUTPUT_DIRECTORY})
set(PACK_LINK_LIB IOStream haplotypecaller logger)
set(PACK_LINK_OPT "-Wl,--no-as-needed")

set(PACK_LINK_DIR ${PACK_LINK_DIR} ${Boost_LIBRARY_DIRS})
if(TARGET Boost::program_options AND NOT ROVACA_USE_BUNDLED_BOOST)
    set(PACK_LINK_LIB ${PACK_LINK_LIB} Boost::program_options)
else()
    set(PACK_LINK_LIB ${PACK_LINK_LIB} ${Boost_LIBRARIES})
endif()

add_library(${PACK_NAME} ${ROVACA_LIB_TYPE} ${PACK_SRC})
target_include_directories(${PACK_NAME} PRIVATE ${PACK_INCLUDE_DIR})
target_link_directories(${PACK_NAME} PRIVATE ${PACK_LINK_DIR})
target_link_libraries(${PACK_NAME} PRIVATE ${PACK_LINK_LIB})
target_link_options(${PACK_NAME} PRIVATE ${PACK_LINK_OPT})

add_executable(${PROJECT_NAME} main.cpp)
if(ROVACA_STATIC)
    # 全静态：--whole-archive 保证静态初始化（工具注册表）不被丢弃
    target_link_options(${PROJECT_NAME} PRIVATE -static -static-libgcc -static-libstdc++)
    target_link_libraries(${PROJECT_NAME} PRIVATE
        -Wl,--whole-archive
        main IOStream haplotypecaller logger region assemble genotype writer pairhmm utils base bqsr
        -Wl,--no-whole-archive
        pthread dl)
else()
    target_link_libraries(${PROJECT_NAME} PRIVATE main)
endif()

if(ENABLE_ASAN)
    include(asan)
    enable_sanitizer(${PACK_NAME})
endif()

if(ENABLE_GCOV)
    include(gcov)
    enable_gcov(${PACK_NAME})
endif()

install(TARGETS ${PACK_NAME} LIBRARY DESTINATION lib ARCHIVE DESTINATION lib RUNTIME DESTINATION lib)
install(TARGETS ${PROJECT_NAME} LIBRARY DESTINATION lib ARCHIVE DESTINATION lib RUNTIME DESTINATION lib)

if(NOT BOOST_PROGRAM_OPTIONS_INSTALL_LIB AND TARGET Boost::program_options)
    get_target_property(BOOST_PROGRAM_OPTIONS_INSTALL_LIB Boost::program_options IMPORTED_LOCATION_RELEASE)
    if(NOT BOOST_PROGRAM_OPTIONS_INSTALL_LIB)
        get_target_property(BOOST_PROGRAM_OPTIONS_INSTALL_LIB Boost::program_options IMPORTED_LOCATION)
    endif()
endif()

if(NOT BOOST_PROGRAM_OPTIONS_INSTALL_LIB)
    if(DEFINED Boost_PROGRAM_OPTIONS_LIBRARY_RELEASE)
        set(BOOST_PROGRAM_OPTIONS_INSTALL_LIB ${Boost_PROGRAM_OPTIONS_LIBRARY_RELEASE})
    elseif(DEFINED Boost_PROGRAM_OPTIONS_LIBRARY)
        set(BOOST_PROGRAM_OPTIONS_INSTALL_LIB ${Boost_PROGRAM_OPTIONS_LIBRARY})
    endif()
endif()

if(BOOST_PROGRAM_OPTIONS_INSTALL_LIB AND EXISTS "${BOOST_PROGRAM_OPTIONS_INSTALL_LIB}")
    install(FILES ${BOOST_PROGRAM_OPTIONS_INSTALL_LIB} DESTINATION lib)
else()
    message(WARNING "Boost program_options shared library not found for install step; skipping install(FILES ...)")
endif()
