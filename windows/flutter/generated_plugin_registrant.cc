//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <ffmpeg_kit_flutter_new_video/f_fmpeg_kit_flutter_plugin.h>
#include <file_selector_windows/file_selector_windows.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FFmpegKitFlutterPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FFmpegKitFlutterPlugin"));
  FileSelectorWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FileSelectorWindows"));
  FlutterWebRTCPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterWebRTCPlugin"));
}
