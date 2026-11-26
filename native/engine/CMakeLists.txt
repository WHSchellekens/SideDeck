# SideDeck native engine (Android: android/app/src/main/cpp/CMakeLists.txt,
# iOS: native/CMakeLists.txt via ios/engine/build_engine.sh).
cmake_minimum_required(VERSION 3.22.1)
project(dj_engine_sources LANGUAGES CXX)
message(STATUS "Engine sources live here; Android builds through app/src/main/cpp.")

# Host unit tests for the engine's pure helpers. Not part of the app builds.
#   cmake -S native/engine -B build/native-tests && cmake --build build/native-tests
#   ctest --test-dir build/native-tests --output-on-failure
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
enable_testing()
add_executable(quantize_test test/quantize_test.cpp)
target_include_directories(quantize_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
add_test(NAME quantize COMMAND quantize_test)
add_executable(onair_test test/onair_test.cpp)
target_include_directories(onair_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
add_test(NAME onair COMMAND onair_test)
add_executable(wave_scan_test test/wave_scan_test.cpp)
target_include_directories(wave_scan_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
add_test(NAME wave_scan COMMAND wave_scan_test)
