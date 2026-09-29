cmake_minimum_required(VERSION 3.20)
project(hdzero_pc_receiver LANGUAGES CXX)

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2 REQUIRED IMPORTED_TARGET sdl2)

add_library(hdzero_codec
    src/codec.cpp
)
target_include_directories(hdzero_codec PUBLIC include)
target_compile_features(hdzero_codec PUBLIC cxx_std_20)

if(MSVC)
    target_compile_options(hdzero_codec PRIVATE /W4 /permissive-)
else()
    target_compile_options(hdzero_codec PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(hdzero_decode src/main.cpp)
target_link_libraries(hdzero_decode PRIVATE hdzero_codec)

add_executable(hdzero_live src/live.cpp)
target_link_libraries(hdzero_live PRIVATE hdzero_codec PkgConfig::SDL2)

include(CTest)
if(BUILD_TESTING)
    add_test(
        NAME decode_base_reference
        COMMAND hdzero_decode
            ${CMAKE_CURRENT_SOURCE_DIR}/../esp32/fs/test/decoder_base.rxt
            --verify-only
    )
    add_test(
        NAME decode_enhancement_reference
        COMMAND hdzero_decode
            ${CMAKE_CURRENT_SOURCE_DIR}/../esp32/fs/test/decoder_enhancement.rxt
            --verify-only
    )
endif()
