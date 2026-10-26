cmake_minimum_required(VERSION 3.14)
project(browser_bridge LANGUAGES CXX)

# The browsers' native messaging host (host.cpp). It goes beside the app's
# executable with the manifest the browsers find it by (the installer's keys
# point there, see tool/baocode.iss), and its "path", relative, is the host
# beside it.
#
# Its name says the product, as the app's does: baocode-browser-host.exe for
# BaoCode Claude, baocode-codex-browser-host.exe for the codex one, so that
# the browser of one product does not talk to the other. The name is not
# only a label: host.cpp reads the port file named after itself, and the app
# writes the port file of its product id — so the Claude Code product keeps
# the name the id says ("baocode", which is also what the published
# extension knows), though its executable is baocode-claude.exe.
#
# The parent scope says the name (windows/CMakeLists.txt) and installs the
# target it names, so this is only the rule for a build of this directory
# alone: it agrees with the parent's, and is not to diverge from it.
if(NOT DEFINED BROWSER_HOST_NAME)
  if(NOT DEFINED BINARY_NAME)
    set(BINARY_NAME "baocode")
  endif()
  if(BINARY_NAME STREQUAL "baocode" OR BINARY_NAME STREQUAL "baocode-claude")
    set(BROWSER_HOST_NAME "baocode-browser-host")
  else()
    set(BROWSER_HOST_NAME "${BINARY_NAME}-browser-host")
  endif()
endif()

add_executable(${BROWSER_HOST_NAME} "host.cpp")
apply_standard_settings(${BROWSER_HOST_NAME})
target_compile_options(${BROWSER_HOST_NAME} PRIVATE /utf-8)
target_compile_definitions(${BROWSER_HOST_NAME} PRIVATE
  "NOMINMAX" "WIN32_LEAN_AND_MEAN")
target_link_libraries(${BROWSER_HOST_NAME} PRIVATE "ws2_32.lib")
