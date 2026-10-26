#include "log_folder.h"

#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <vector>

#include "app_identity.h"
#include "utils.h"

namespace log_folder {
namespace {

constexpr wchar_t kFolderValue[] = L"LogsFolder";

// The most lines a run writes to tray.log, and the size past which the
// next run starts it anew (the old one kept as tray.1.log).
constexpr int kMaxTrayLogLines = 300;
constexpr ULONGLONG kMaxTrayLogBytes = 1024 * 1024;

// Windows' own lock, not std::mutex: built with MSVC 14.40 or later, a
// std::mutex is constexpr-constructed and crashes in msvcp140.dll's
// _Mtx_lock where the VC++ runtime installed is older — which is most
// machines, the app not carrying its own. Path() runs as the app starts
// (the hang watchdog's folder), so every launch crashed before a window
// showed.
SRWLOCK g_lock = SRWLOCK_INIT;

// g_lock held for as long as it is in scope.
class Locked {
 public:
  Locked() { ::AcquireSRWLockExclusive(&g_lock); }
  ~Locked() { ::ReleaseSRWLockExclusive(&g_lock); }
  Locked(const Locked&) = delete;
  Locked& operator=(const Locked&) = delete;
};

// The folder Flutter named this run; empty until it does.
std::wstring g_folder;

// The folder kept by the run before; empty if none.
std::wstring KeptFolder() {
  // The product's own key: the two products keep their logs apart.
  const std::wstring key = SettingsKey();
  DWORD size = 0;
  if (::RegGetValueW(HKEY_CURRENT_USER, key.c_str(), kFolderValue,
                     RRF_RT_REG_SZ, nullptr, nullptr,
                     &size) != ERROR_SUCCESS ||
      size < sizeof(wchar_t)) {
    return std::wstring();
  }
  std::vector<wchar_t> folder(size / sizeof(wchar_t) + 1, L'\0');
  size = static_cast<DWORD>(folder.size() * sizeof(wchar_t));
  if (::RegGetValueW(HKEY_CURRENT_USER, key.c_str(), kFolderValue,
                     RRF_RT_REG_SZ, nullptr, folder.data(),
                     &size) != ERROR_SUCCESS) {
    return std::wstring();
  }
  return std::wstring(folder.data());
}

// %APPDATA%\baocode\logs (the codex product's own folder); empty if there
// is no %APPDATA%.
std::wstring DefaultFolder() {
  wchar_t app_data[MAX_PATH];
  const DWORD length =
      ::GetEnvironmentVariableW(L"APPDATA", app_data, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::wstring();
  }
  // The Claude Code product keeps the folder it always had, though its
  // executable carries the "claude" suffix now: its data folder is the same
  // one, and the logs belong beside it.
  const std::wstring product = ProductSuffix();
  if (product.empty() || product == L"claude") {
    return std::wstring(app_data) + L"\\baocode\\logs";
  }
  return std::wstring(app_data) + L"\\baocode-" + product + L"\\logs";
}

// Whether |folder| is there, made if need be — with the folders above it:
// the data folder may not be there yet.
bool Made(const std::wstring& folder) {
  const int made = ::SHCreateDirectoryExW(nullptr, folder.c_str(), nullptr);
  return made == ERROR_SUCCESS || made == ERROR_ALREADY_EXISTS ||
         made == ERROR_FILE_EXISTS;
}

void SetFolder(const std::wstring& folder) {
  {
    Locked locked;
    g_folder = folder;
  }
  const std::wstring key = SettingsKey();
  ::RegSetKeyValueW(HKEY_CURRENT_USER, key.c_str(), kFolderValue, REG_SZ,
                    folder.c_str(),
                    static_cast<DWORD>((folder.size() + 1) * sizeof(wchar_t)));
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> Listen(
    flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "baocode/logs", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "setFolder") {
          result->NotImplemented();
          return;
        }
        const auto* path = call.arguments() == nullptr
                               ? nullptr
                               : std::get_if<std::string>(call.arguments());
        if (path != nullptr && !path->empty()) {
          SetFolder(Utf16FromUtf8(*path));
        }
        result->Success();
      });
  return channel;
}

std::wstring Path() {
  std::wstring named;
  {
    Locked locked;
    named = g_folder;
  }
  if (named.empty()) {
    named = KeptFolder();
  }
  if (!named.empty() && Made(named)) {
    return named;
  }
  // None named yet, or the one named is out of reach (a drive gone).
  const std::wstring fallback = DefaultFolder();
  if (!fallback.empty() && fallback != named && Made(fallback)) {
    return fallback;
  }
  return std::wstring();
}

void WriteTrayLog(const char* format, ...) {
  static int lines = 0;
  if (lines >= kMaxTrayLogLines) {
    return;
  }
  // The folder, and where it is when there is none yet: the tray is put
  // up before Flutter has named the data folder, and what it did is
  // worth saying wherever it can be said.
  std::wstring folder = Path();
  if (folder.empty()) {
    folder = DefaultFolder();
  }
  // The line, written where it is wanted: the data folder's logs, or the
  // system's temporary folder when that is out of reach.
  wchar_t temporary[MAX_PATH] = {};
  ::GetTempPathW(MAX_PATH, temporary);
  std::wstring line;
  {
    SYSTEMTIME now = {};
    ::GetLocalTime(&now);
    char text[1024] = {};
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof(text), format, arguments);
    va_end(arguments);
    wchar_t head[64] = {};
    _snwprintf_s(head, 64, _TRUNCATE,
                 L"%04u-%02u-%02u %02u:%02u:%02u.%03u ", now.wYear,
                 now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
                 now.wMilliseconds);
    line = std::wstring(head) + Utf16FromUtf8(text) + L"\n";
  }
  for (const std::wstring& where :
       {folder, std::wstring(temporary)}) {
    if (where.empty()) {
      continue;
    }
    const std::wstring path = where + L"\\tray.log";
    FILE* out = nullptr;
    if (_wfopen_s(&out, path.c_str(), L"a") != 0 || out == nullptr) {
      continue;
    }
    ::fputws(line.c_str(), out);
    std::fclose(out);
    lines++;
    if (where == folder) {
      break;
    }
  }
}

}  // namespace log_folder
