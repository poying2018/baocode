#include "app_identity.h"

#include <windows.h>

#include <cwctype>
#include <string>

const wchar_t* const kAppIdVariable = L"BAOCODE_APP_ID";

namespace {

// The window class the runner's windows have, as the app is released.
constexpr wchar_t kRunnerClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// The name the app is released as, which every product's executable
// carries a suffix of: baocode-claude.exe, baocode-codex.exe.
constexpr wchar_t kAppName[] = L"baocode";

// The name this program was started as, without its folder or .exe.
std::wstring ExecutableName() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD written =
        ::GetModuleFileNameW(nullptr, path.data(), (DWORD)path.size());
    if (written == 0) {
      return std::wstring();
    }
    if (written < path.size()) {
      path.resize(written);
      break;
    }
    // Longer than the buffer: the answer is the length it needs.
    path.resize(written + 1);
  }
  const size_t slash = path.find_last_of(L"\\/");
  std::wstring name = slash == std::wstring::npos ? path : path.substr(slash + 1);
  const size_t dot = name.find_last_of(L'.');
  if (dot != std::wstring::npos) {
    name.resize(dot);
  }
  for (wchar_t& c : name) {
    c = (wchar_t)::towlower(c);
  }
  return name;
}

// [name] as it may be in a window class: letters, digits and underscores
// only, and not too long (the class name is a resource).
std::wstring ClassSafe(const std::wstring& name) {
  std::wstring safe;
  for (const wchar_t c : name) {
    if ((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') ||
        (c >= L'0' && c <= L'9') || c == L'_') {
      safe.push_back(c);
    } else if (!safe.empty()) {
      safe.push_back(L'_');
    }
    if (safe.size() >= 32) break;
  }
  return safe;
}

// The environment's value for [name]: what is around it is not part of it.
std::wstring EnvironmentName(const wchar_t* name) {
  const DWORD needed = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (needed == 0) {
    return std::wstring();
  }
  std::wstring value(needed, L'\0');
  const DWORD written = ::GetEnvironmentVariableW(name, value.data(), needed);
  value.resize(written);
  size_t start = 0;
  while (start < value.size() &&
         (value[start] == L' ' || value[start] == L'\t')) {
    start++;
  }
  value.erase(0, start);
  while (!value.empty() && (value.back() == L' ' || value.back() == L'\t')) {
    value.pop_back();
  }
  return value;
}

// [text] as a title's word: its first letter up, the rest as it was.
std::wstring Capitalised(const std::wstring& text) {
  if (text.empty()) return text;
  std::wstring word = text;
  word[0] = (wchar_t)::towupper(word[0]);
  return word;
}

}  // namespace

std::wstring ProductSuffix() {
  const std::wstring name = ExecutableName();
  const std::wstring prefix = std::wstring(kAppName) + L"-";
  if (name.size() <= prefix.size() || name.compare(0, prefix.size(), prefix) != 0) {
    return std::wstring();
  }
  return name.substr(prefix.size());
}

std::wstring AppId() { return EnvironmentName(kAppIdVariable); }

const wchar_t* AppWindowClass() {
  static const std::wstring* class_name = [] {
    std::wstring name = kRunnerClass;
    if (const std::wstring product = ClassSafe(ProductSuffix());
        !product.empty()) {
      name += L"_" + product;
    }
    if (const std::wstring id = ClassSafe(AppId()); !id.empty()) {
      name += L"_" + id;
    }
    return new std::wstring(name);
  }();
  return class_name->c_str();
}

std::wstring AppWindowTitle() {
  std::wstring title = L"BaoCode";
  if (const std::wstring product = ProductSuffix(); !product.empty()) {
    title += L" " + Capitalised(product);
  }
  if (const std::wstring id = AppId(); !id.empty()) {
    title += L" (" + id + L")";
  }
  return title;
}

std::wstring SettingsKey() {
  // The product's own key: the codex product keeps its settings under
  // Software\BaoCodeCodex, so that the two do not write over each
  // other's (the window's frame, the folder the logs go in).
  //
  // The Claude Code product keeps the key it always had (Software\BaoCode),
  // though its executable carries the "claude" suffix: its settings are
  // where they have been since before the rename, and a new key would
  // leave them behind.
  const std::wstring product = ProductSuffix();
  if (product.empty() || product == L"claude") {
    return std::wstring(L"Software\\BaoCode");
  }
  return std::wstring(L"Software\\BaoCode") + Capitalised(product);
}

std::wstring SingleInstanceName() {
  // The mutex is the product's own: a copy of the Claude Code product
  // running must not keep the codex product from starting (each has
  // windows of its own class, so neither hands its paths to the other).
  //
  // The Claude Code product keeps the name it always had, though its
  // executable carries the "claude" suffix now: it keeps the same data
  // folder, and two copies of one product writing into it are worse than
  // one handing its paths to the other.
  std::wstring name = L"Local\\BaoCode.SingleInstance";
  const std::wstring product = ProductSuffix();
  if (!product.empty() && product != L"claude") {
    name += L"." + product;
  }
  if (const std::wstring id = AppId(); !id.empty()) {
    name += L"." + id;
  }
  return name;
}
