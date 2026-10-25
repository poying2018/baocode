#include "app_identity.h"

#include <windows.h>

#include <string>
#include <vector>

const wchar_t* const kAppIdVariable = L"BAOCODE_APP_ID";

namespace {

// The window class the runner's windows have, as the app is released.
constexpr wchar_t kRunnerClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// The id as it may be in a window class: letters, digits and underscores
// only, and not too long (the class name is a resource).
std::wstring ClassSafeId(const std::wstring& id) {
  std::wstring safe;
  for (const wchar_t c : id) {
    if ((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') ||
        (c >= L'0' && c <= L'9') || c == L'_') {
      safe.push_back(c);
    } else {
      safe.push_back(L'_');
    }
    if (safe.size() >= 32) break;
  }
  return safe;
}

}  // namespace

std::wstring AppId() {
  const DWORD needed = ::GetEnvironmentVariableW(kAppIdVariable, nullptr, 0);
  if (needed == 0) {
    return std::wstring();
  }
  std::wstring value(needed, L'\0');
  const DWORD written = ::GetEnvironmentVariableW(kAppIdVariable, value.data(),
                                                 needed);
  value.resize(written);
  // The id is a name, not a path: what is around it does not belong to it.
  while (!value.empty() && (value.back() == L' ' || value.back() == L'\t')) {
    value.pop_back();
  }
  size_t start = 0;
  while (start < value.size() &&
         (value[start] == L' ' || value[start] == L'\t')) {
    start++;
  }
  value.erase(0, start);
  return value;
}

const wchar_t* AppWindowClass() {
  static const std::wstring* class_name = [] {
    const std::wstring id = ClassSafeId(AppId());
    if (id.empty()) {
      return new std::wstring(kRunnerClass);
    }
    return new std::wstring(std::wstring(kRunnerClass) + L"_" + id);
  }();
  return class_name->c_str();
}

std::wstring AppWindowTitle(const wchar_t* product) {
  const std::wstring id = AppId();
  if (id.empty()) {
    return std::wstring(product);
  }
  return std::wstring(product) + L" (" + id + L")";
}
