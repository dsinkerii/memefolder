cmake_minimum_required(VERSION 3.10)
project(mel_ffi C)

set(CMAKE_C_STANDARD 11)

add_library(mel_ffi SHARED mel_ffi.c)
target_link_libraries(mel_ffi m)

add_executable(test_mel test_mel.c)
target_link_libraries(test_mel mel_ffi)

install(TARGETS mel_ffi LIBRARY DESTINATION lib)
