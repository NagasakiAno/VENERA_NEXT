cmake_minimum_required(VERSION 3.5)
project(entry)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(entry SHARED
    napi_init.cpp
    jsvm_engine.cpp
)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libjsvm.so
    libhilog_ndk.z.so
)
