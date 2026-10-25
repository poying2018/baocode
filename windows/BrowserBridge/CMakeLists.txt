cmake_minimum_required(VERSION 3.14)
project(browser_bridge LANGUAGES CXX)

# The browsers' native messaging host (host.cpp). It goes beside the app's
# executable with the manifest the browsers find it by (the installer's keys
# point there, see tool/baocode.iss), and its "path", relative, is the host
# beside it.
#
# Its name says the product, as the app's does: baocode-browser-host.exe for
# BaoCode, baocode-codex-browser-host.exe for the codex one, so that the
# browser of one product does not talk to the other (host.cpp reads the port
# file of the product it belongs to). The app's name is in the parent
# scope (BINARY_NAME, which tool/set_product.dart writes).
if(NOT DEFINED BINARY_NAME)
  set(BINARY_NAME "baocode")
endif()
if("${BINARY_NAME}" STREQUAL "baocode")
  set(BROWSER_HOST_NAME "baocode-browser-host")
else()
  set(BROWSER_HOST_NAME "${BINARY_NAME}-browser-host")
endif()

add_executable(${BROWSER_HOST_NAME} "host.cpp")
apply_standard_settings(${BROWSER_HOST_NAME})
target_compile_options(${BROWSER_HOST_NAME} PRIVATE /utf-8)
target_compile_definitions(${BROWSER_HOST_NAME} PRIVATE
  "NOMINMAX" "WIN32_LEAN_AND_MEAN")
target_link_libraries(${BROWSER_HOST_NAME} PRIVATE "ws2_32.lib")
