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

add_library(hdzero_monitor
    src/raw_monitor.cpp
)
target_include_directories(hdzero_monitor PUBLIC include)
target_compile_features(hdzero_monitor PUBLIC cxx_std_20)

add_executable(hdzero_live src/live.cpp)
target_link_libraries(hdzero_live PRIVATE
    hdzero_codec hdzero_monitor PkgConfig::SDL2
)

include(CTest)
if(BUILD_TESTING)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)

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
    add_test(
        NAME live_packet_loss_gray
        COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_live_packet_loss.py
            $<TARGET_FILE:hdzero_live>
            ${CMAKE_CURRENT_SOURCE_DIR}/../esp32/fs/test/decoder_enhancement.rxt
    )
    set_tests_properties(live_packet_loss_gray PROPERTIES TIMEOUT 15)

    add_executable(raw_monitor_test tests/test_raw_monitor.cpp)
    target_link_libraries(raw_monitor_test PRIVATE hdzero_monitor)
    add_test(NAME raw_monitor_parser COMMAND raw_monitor_test)
endif()
