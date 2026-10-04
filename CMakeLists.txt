cmake_minimum_required(VERSION 3.16)
project(rovaca VERSION 1.1.0) # 发版时在此更改版本号
if(${CMAKE_VERSION} VERSION_GREATER_EQUAL "3.27")
    cmake_policy(SET CMP0003 NEW)
    cmake_policy(SET CMP0144 NEW)
endif()

include(GNUInstallDirs)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_INCLUDE_CURRENT_DIR ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)
set(CMAKE_INSTALL_RPATH "$ORIGIN")
# SET(CMAKE_BUILD_RPATH_USE_ORIGIN TRUE)


set(CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake)
set(EXECUTABLE_OUTPUT_PATH ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${EXECUTABLE_OUTPUT_PATH})
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${EXECUTABLE_OUTPUT_PATH})

if(CMAKE_BUILD_TYPE AND (CMAKE_BUILD_TYPE STREQUAL "Debug"))
    set(CMAKE_C_FLAGS "-Wall -Wextra -O0 -g -fPIC")
    set(CMAKE_CXX_FLAGS "-Wall -Wextra -O0 -g -fPIC")
else()
    set(CMAKE_C_FLAGS "-Wall -Wextra -O3  -g -fPIC")
    set(CMAKE_CXX_FLAGS "-Wall -Wextra -O3  -g -fPIC")
endif()

set(MIN_BOOST_VERSION 1.69)
# Boost is resolved in src/CMakeLists.txt with a system-first and local-fallback strategy.

option(ENABLE_GCOV "Enable Gcov" OFF)
option(ENABLE_ASAN "Enable Address Sanitizer" OFF)
option(ENABLE_GOOGLE_TEST "Enable Google Test" OFF)
option(ROVACA_STATIC "Link a fully static rovaca executable (deps expected under third_lib/static-deps, see build_static.sh)" OFF)

set(ROVACA_LIB_TYPE SHARED)
if(ROVACA_STATIC)
    set(ROVACA_LIB_TYPE STATIC)
    # static deps (libhts.a, libz.a, libbz2.a, liblzma.a, libboost_program_options.a + boost headers)
    # are prepared by build_static.sh under third_lib/static-deps
    include_directories(${CMAKE_SOURCE_DIR}/third_lib/static-deps/include)
endif()

if(ENABLE_GCOV)
    include(gcov)
    message(STATUS "* * * * * * * * * * * Gcov Enabled * * * * * * * * * * *")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} --coverage")
endif()

if(ENABLE_ASAN)
    include(asan)
    message(STATUS "* * * * * * * * * * * Address Sanitizer Enabled * * * * * * * * * * *")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=address")
endif()

if(ENABLE_GOOGLE_TEST)
    message(STATUS "* * * * * * * * * * * Google Test Enabled * * * * * * * * * * *")
    set(GTest_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_lib/googletest-1.14.0/lib64/cmake/GTest)
    find_package(GTest REQUIRED COMPONENTS)
    if(GTest_FOUND)
        message(STATUS "* * * * * * * * * * * google test version: ${GTest_VERSION} * * * * * * * * * * *")
    endif()
    enable_testing()
endif()

set(HTSLIB_DIR ${CMAKE_SOURCE_DIR}/third_lib/htslib)
set(HTSLIB_INCLUDE_DIR ${HTSLIB_DIR}/include)
set(HTSLIB_LIBRARY_DIR ${HTSLIB_DIR}/lib)

set(SPDLOG_DIR ${CMAKE_SOURCE_DIR}/third_lib/spdlog)
set(SPDLOG_INCLUDE_DIR ${SPDLOG_DIR}/include)
set(SPDLOG_LIBRARY_DIR ${SPDLOG_DIR}/lib64)

if(ROVACA_STATIC)
    add_library(hts STATIC IMPORTED)
    set_target_properties(hts PROPERTIES IMPORTED_LOCATION ${CMAKE_SOURCE_DIR}/third_lib/static-deps/lib/libhts.a
        INTERFACE_LINK_LIBRARIES "${CMAKE_SOURCE_DIR}/third_lib/static-deps/lib/libz.a;${CMAKE_SOURCE_DIR}/third_lib/static-deps/lib/libbz2.a;${CMAKE_SOURCE_DIR}/third_lib/static-deps/lib/liblzma.a")
else()
    if(NOT EXISTS ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/libhts.so.3)
        file(COPY ${HTSLIB_LIBRARY_DIR}/libhts.so.1.18-1-g6dbcddf DESTINATION ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}
             FILE_PERMISSIONS OWNER_READ OWNER_WRITE GROUP_READ WORLD_READ)
        file(RENAME ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/libhts.so.1.18-1-g6dbcddf ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/libhts.so.3)
    endif()

    add_library(hts SHARED IMPORTED)
    set_target_properties(hts PROPERTIES IMPORTED_LOCATION ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/libhts.so.3)
endif()

add_subdirectory(src)
if(NOT ROVACA_STATIC)
    set(ROVACA_LIBDEFLATE_INSTALL_PATH "")
    set(ROVACA_LIBDEFLATE_CANDIDATES
        "/usr/local/lib/libdeflate.so.0"
        "/lib/x86_64-linux-gnu/libdeflate.so.0"
        "${CMAKE_SOURCE_DIR}/libdeflate.so.0")
    foreach(ROVACA_LIBDEFLATE_CANDIDATE IN LISTS ROVACA_LIBDEFLATE_CANDIDATES)
        if(EXISTS "${ROVACA_LIBDEFLATE_CANDIDATE}")
            set(ROVACA_LIBDEFLATE_INSTALL_PATH "${ROVACA_LIBDEFLATE_CANDIDATE}")
            break()
        endif()
    endforeach()

    if(ROVACA_LIBDEFLATE_INSTALL_PATH)
        install(FILES "${ROVACA_LIBDEFLATE_INSTALL_PATH}" DESTINATION lib)
    else()
        message(FATAL_ERROR "libdeflate.so.0 not found in system paths or source directory")
    endif()
    install(FILES ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/libhts.so.3 DESTINATION lib)
endif()
