cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "live2d_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)
cmake_policy(VERSION 3.14...3.25)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(PLUGIN_NAME "live2d_flutter_plugin")
set(NATIVE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp")
set(CORE_INCLUDE_PATH "${NATIVE_PATH}/CubismCore/include")
set(FRAMEWORK_PATH "${NATIVE_PATH}/CubismFramework")
set(CORE_LIBRARY_PATH "${CMAKE_CURRENT_SOURCE_DIR}/libs/x86_64/143")

add_library(Live2DCubismCore STATIC IMPORTED)
set_target_properties(Live2DCubismCore PROPERTIES
  IMPORTED_LOCATION_DEBUG
    "${CORE_LIBRARY_PATH}/Live2DCubismCore_MDd.lib"
  IMPORTED_LOCATION_RELEASE
    "${CORE_LIBRARY_PATH}/Live2DCubismCore_MD.lib"
  IMPORTED_LOCATION_RELWITHDEBINFO
    "${CORE_LIBRARY_PATH}/Live2DCubismCore_MD.lib"
  IMPORTED_LOCATION_MINSIZEREL
    "${CORE_LIBRARY_PATH}/Live2DCubismCore_MD.lib"
  IMPORTED_LOCATION_PROFILE
    "${CORE_LIBRARY_PATH}/Live2DCubismCore_MD.lib"
  INTERFACE_INCLUDE_DIRECTORIES "${CORE_INCLUDE_PATH}"
)

file(GLOB_RECURSE FRAMEWORK_SOURCES CONFIGURE_DEPENDS
  "${FRAMEWORK_PATH}/*.cpp"
)
list(FILTER FRAMEWORK_SOURCES EXCLUDE REGEX ".*/D3D9/.*")
list(FILTER FRAMEWORK_SOURCES EXCLUDE REGEX ".*/Metal/.*")
list(FILTER FRAMEWORK_SOURCES EXCLUDE REGEX ".*/OpenGL/.*")
list(FILTER FRAMEWORK_SOURCES EXCLUDE REGEX ".*/Vulkan/.*")

add_library(CubismFrameworkWindows STATIC ${FRAMEWORK_SOURCES})
target_include_directories(CubismFrameworkWindows
  PUBLIC "${FRAMEWORK_PATH}"
  PRIVATE "${CORE_INCLUDE_PATH}"
)
target_compile_options(CubismFrameworkWindows PRIVATE /MP)
target_link_libraries(CubismFrameworkWindows
  PUBLIC Live2DCubismCore
  PRIVATE d3d11.lib d3dcompiler.lib
)

list(APPEND PLUGIN_SOURCES
  "flutter_live2d_plugin.cpp"
  "flutter_live2d_plugin.h"
  "Live2DAllocator.cpp"
  "Live2DAllocator.hpp"
  "Live2DModel.cpp"
  "Live2DModel.hpp"
  "Live2DPal.cpp"
  "Live2DPal.hpp"
  "Live2DTextureManager.cpp"
  "Live2DTextureManager.hpp"
  "Live2DWindowsView.cpp"
  "Live2DWindowsView.hpp"
)

add_library(${PLUGIN_NAME} SHARED
  "include/live2d_flutter/flutter_live2d_plugin_c_api.h"
  "flutter_live2d_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  FLUTTER_PLUGIN_IMPL
  _CRT_SECURE_NO_WARNINGS
)
target_include_directories(${PLUGIN_NAME}
  INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CORE_INCLUDE_PATH}"
    "${FRAMEWORK_PATH}"
    "${NATIVE_PATH}"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  CubismFrameworkWindows
  Live2DCubismCore
  d3d11.lib
  d3dcompiler.lib
  dxgi.lib
)

add_custom_command(TARGET ${PLUGIN_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    "${FRAMEWORK_PATH}/Rendering/D3D11/Shaders"
    "$<TARGET_FILE_DIR:${PLUGIN_NAME}>/FrameworkShaders"
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    "${FRAMEWORK_PATH}/Rendering/D3D11/Shaders"
    "${CMAKE_BINARY_DIR}/runner/$<CONFIG>/FrameworkShaders"
)

set(live2d_flutter_bundled_libraries "" PARENT_SCOPE)
