cmake_minimum_required(VERSION 3.18)
project(libpunch_reimpl CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# ---- 平台开关（r683：iOS 静态库）----
# iOS 上：① 不允许随便带 dylib（要签名/嵌入），所以 `synochatpunch` 编成 **static**，
#          由 Runner 用 `-force_load` 整体链进去，Dart 走 `DynamicLibrary.process()`；
#        ② SDK 里没有 libcurl（`http.cpp` 用不到 —— echo 发现本来就在 Dart 侧做），
#          所以跳过 libcurl 与 `test_http`；
#        ③ 测试可执行文件不参与 App 构建（用宿主 `ctest` 跑即可）。
option(PUNCH_IOS "Build for iOS (static lib, no libcurl, no test executables)" OFF)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  set(PUNCH_IOS ON)
endif()

add_compile_options(-Wall -Wextra)

# ---- 协议层（纯逻辑，无平台依赖，可在宿主机测试）----
add_library(punch_protocol STATIC
  src/protocol.cpp
)
target_include_directories(punch_protocol PUBLIC include)

# ---- udt4（第三方，BSD-3-Clause，University of Illinois）----
# 原库静态链接的就是 udt4；这里改用源码方式引入，不打包任何 Synology 二进制。
file(GLOB UDT4_SOURCES third_party/udt4/src/*.cpp)
add_library(udt4 STATIC ${UDT4_SOURCES})
# SYSTEM：udt4 上游代码在 -Wall -Wextra 下会报若干告警，不作为本项目的质量问题
target_include_directories(udt4 SYSTEM PUBLIC
  third_party/udt4
  third_party/udt4/src
)
set_target_properties(udt4 PROPERTIES CXX_STANDARD 14 CXX_STANDARD_REQUIRED ON)
# udt4 上游源码在 -Wall -Wextra 下自带若干告警（未使用参数、无效预处理指令等）。
# 这些不是本项目的质量问题，也不打算改上游源码，故对第三方 target 关闭告警。
# 本项目自身的代码（src/、tests/）仍然全量开启 -Wall -Wextra。
if(NOT MSVC)
  target_compile_options(udt4 PRIVATE -w)
endif()
find_package(Threads REQUIRED)
target_link_libraries(udt4 PUBLIC Threads::Threads)

# ---- 套接字层（POSIX，可在宿主机测试）----
add_library(punch_socket STATIC
  src/socket.cpp
  src/udt_socket.cpp
)
target_include_directories(punch_socket PUBLIC include)
target_link_libraries(punch_socket PUBLIC udt4)

# ---- 打洞服务器发现：纯逻辑部分（JSON 解析 + echo list 请求构造/响应解析）----
# 无平台依赖，Android 上同样可构建。
add_library(punch_discovery STATIC
  src/json.cpp
  src/punch_server.cpp
)
target_include_directories(punch_discovery PUBLIC include)

# ---- libcurl 封装：仅宿主构建 ----
# Android NDK 不自带 libcurl；且 echo 发现由 Flutter 侧用 Dio 完成，
# 原生层只通过 synopunch_add_echo_server() 接收服务器列表，因此不需要它。
if(NOT ANDROID AND NOT PUNCH_IOS)
  find_package(CURL REQUIRED)
  add_library(punch_http STATIC
    src/http.cpp
  )
  target_include_directories(punch_http PUBLIC include)
  target_link_libraries(punch_http PUBLIC punch_discovery PRIVATE CURL::libcurl)
endif()

# ---- 隧道会话复用（流重组）----
add_library(punch_relay STATIC
  src/relay_buffer.cpp
  src/relay_session.cpp
  src/relay_engine.cpp
  src/relay_client.cpp
)
target_include_directories(punch_relay PUBLIC include)
target_link_libraries(punch_relay PUBLIC punch_protocol punch_socket)

# ---- 打洞交换 ----
add_library(punch_exchange STATIC
  src/punch_exchange.cpp
)
target_include_directories(punch_exchange PUBLIC include)
target_link_libraries(punch_exchange PUBLIC punch_protocol punch_socket)

# ---- 测试（宿主才有；iOS 只出库）----
if(NOT PUNCH_IOS)
enable_testing()
add_executable(test_protocol tests/test_protocol.cpp)
target_link_libraries(test_protocol PRIVATE punch_protocol)

add_executable(test_socket tests/test_socket.cpp)
target_link_libraries(test_socket PRIVATE punch_socket)

add_executable(test_punch_server tests/test_punch_server.cpp)
target_link_libraries(test_punch_server PRIVATE punch_discovery)

if(NOT ANDROID AND NOT PUNCH_IOS)
  add_executable(test_http tests/test_http.cpp)
  target_link_libraries(test_http PRIVATE punch_http)
endif()

add_executable(test_punch_exchange tests/test_punch_exchange.cpp)
target_link_libraries(test_punch_exchange PRIVATE punch_exchange)

add_executable(test_relay_buffer tests/test_relay_buffer.cpp)
target_link_libraries(test_relay_buffer PRIVATE punch_relay)

add_executable(test_relay_session tests/test_relay_session.cpp)
target_link_libraries(test_relay_session PRIVATE punch_relay)

add_executable(test_relay_engine tests/test_relay_engine.cpp)
target_link_libraries(test_relay_engine PRIVATE punch_relay)

add_executable(test_relay_client tests/test_relay_client.cpp)
target_link_libraries(test_relay_client PRIVATE punch_relay punch_exchange punch_discovery)

add_executable(test_udt tests/test_udt.cpp)
target_link_libraries(test_udt PRIVATE punch_socket)

add_test(NAME protocol       COMMAND test_protocol)
add_test(NAME socket         COMMAND test_socket)
add_test(NAME punch_server   COMMAND test_punch_server)
if(NOT ANDROID AND NOT PUNCH_IOS)
  add_test(NAME http           COMMAND test_http)
endif()
add_test(NAME punch_exchange COMMAND test_punch_exchange)
add_test(NAME udt            COMMAND test_udt)
add_test(NAME relay_buffer   COMMAND test_relay_buffer)
add_test(NAME relay_session  COMMAND test_relay_session)
add_test(NAME relay_engine   COMMAND test_relay_engine)
add_test(NAME relay_client   COMMAND test_relay_client)

endif()  # NOT PUNCH_IOS（测试）

# ---- C ABI / 打包 ----
# 宿主/Android：共享库（.so/.dylib）；iOS：**静态库**（static），由 Runner `-force_load`。

# 有意不依赖 libcurl：echo 服务器发现放在宿主侧（Flutter 用 Dio）完成，
# 原生层通过 synopunch_add_echo_server() 接收服务器列表。
# 这样 Android 上不需要为 NDK 另外编译一份 libcurl。
add_library(punch_c STATIC
  src/punch_c.cpp
)
target_include_directories(punch_c PUBLIC include)
target_link_libraries(punch_c PUBLIC punch_relay punch_exchange)

if(PUNCH_IOS)
  add_library(synochatpunch STATIC src/punch_c.cpp)
else()
  add_library(synochatpunch SHARED src/punch_c.cpp)
endif()
target_include_directories(synochatpunch PUBLIC include)
target_link_libraries(synochatpunch
  PRIVATE punch_relay punch_exchange punch_protocol punch_socket
)
set_target_properties(synochatpunch PROPERTIES
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  POSITION_INDEPENDENT_CODE ON
)

if(ANDROID)
  find_library(log-lib log)
  target_link_libraries(synochatpunch PRIVATE ${log-lib})
endif()

# ---- C ABI 测试（宿主）----
if(NOT PUNCH_IOS)
  add_executable(test_punch_c tests/test_punch_c.cpp)
  target_link_libraries(test_punch_c PRIVATE punch_c)
  add_test(NAME punch_c COMMAND test_punch_c)
endif()
