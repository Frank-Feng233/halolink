# HaloLink native decoder (NAPI C++ / AVCodec Kit)
cmake_minimum_required(VERSION 3.5.0)
project(halolink_decoder)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${NATIVERENDER_ROOT_PATH})
include_directories(${NATIVERENDER_ROOT_PATH}/include)

add_library(decoder SHARED
    napi_init.cpp
    video_decoder.cpp
    annexb_parser.cpp
)

target_link_libraries(decoder PUBLIC
    libace_napi.z.so
    libnative_window.so
    libnative_media_vdec.so
    libnative_media_core.so
    libnative_media_codecbase.so
    libnative_buffer.so
    libhilog_ndk.z.so
)
