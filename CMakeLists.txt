cmake_minimum_required(VERSION 3.21)

project(FastFileTransfer LANGUAGES CXX)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)

# Networking
FetchContent_Declare(
    asio
    GIT_REPOSITORY https://github.com/chriskohlhoff/asio.git
    GIT_TAG asio-1-30-2
)
FetchContent_MakeAvailable(asio)
# JSON
FetchContent_Declare(
    json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG v3.12.0
)
FetchContent_MakeAvailable(json)

add_executable(FastFileTransfer
    src/main.cpp
    src/Server.cpp
    src/FolderInfo.cpp
    src/FileInfo.cpp
)

target_link_libraries(FastFileTransfer PRIVATE
    nlohmann_json::nlohmann_json
)

target_include_directories(FastFileTransfer
    SYSTEM PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${asio_SOURCE_DIR}/asio/include
)

target_compile_definitions(FastFileTransfer PRIVATE
    ASIO_STANDALONE
)

target_compile_options(FastFileTransfer PRIVATE
    -Wall
    -Wextra
    -Wconversion
    -Wsign-conversion
    -pedantic
)
