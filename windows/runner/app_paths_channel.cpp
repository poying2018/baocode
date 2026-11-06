#include "app_paths_channel.h"

#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <windows.h>

#include <string>

#include "utils.h"

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> ListenAppPaths(
    flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "baocode/app_paths", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "localAppData") {
          result->NotImplemented();
          return;
        }
        PWSTR folder = nullptr;
        const HRESULT found = ::SHGetKnownFolderPath(
            FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr, &folder);
        if (FAILED(found) || folder == nullptr) {
          result->Error("local-app-data", "Windows has no local app data folder.");
          return;
        }
        const std::string path = Utf8FromUtf16(folder);
        ::CoTaskMemFree(folder);
        result->Success(flutter::EncodableValue(path));
      });
  return channel;
}
