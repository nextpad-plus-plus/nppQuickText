cmake_minimum_required(VERSION 3.20)
project(nppQuickText LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

set(NPP_MACOS_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

add_library(nppQuickText SHARED src/nppQuickText.mm)
target_include_directories(nppQuickText PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE})
target_link_libraries(nppQuickText PRIVATE "-framework Cocoa")
set_target_properties(nppQuickText PROPERTIES PREFIX "" SUFFIX ".dylib")
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.notepad++/plugins/nppQuickText")
install(TARGETS nppQuickText DESTINATION "${PLUGIN_INSTALL_DIR}")
