cmake_minimum_required(VERSION 3.29)

project(Sample LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
include(CTest)

# Resolve the shared Ludus SDK. The CLI/Editor supply LUDUS_SDK_PREFIX via the
# generated preset; no engine source is compiled by this project (P01/P12).
find_package(Ludus CONFIG REQUIRED)

add_executable(Sample src/main.cpp)
target_link_libraries(Sample PRIVATE Ludus::FoundationBase)

# Apply the supported application compile/link policy (C++23, no exceptions)
# without importing engine build warnings or private targets.
if(NOT COMMAND ludus_apply_app_policy)
    message(FATAL_ERROR "The selected SDK lacks the supported Ludus application policy helper")
endif()
ludus_apply_app_policy(Sample)

if(BUILD_TESTING)
    add_test(NAME version_query COMMAND $<TARGET_FILE:Sample>)
    set_tests_properties(version_query PROPERTIES TIMEOUT 20)
endif()
