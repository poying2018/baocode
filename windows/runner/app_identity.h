// Which product this copy of the app is, and which copy of it: a
// development build and the installed one are the same program, and must
// not meet (the one would hand its paths to the other, see
// open_requests.cpp, and their windows would look alike in the taskbar).
// So are the two products built from these sources — BaoCode Claude (the
// Claude Code one) and the codex one.
//
// The product is said by the executable's own name: baocode-claude.exe is
// BaoCode Claude, baocode-codex.exe is the codex one, the part after the
// dash. The copy's id is said by BAOCODE_APP_ID in the environment ("dev"),
// for a build of either product that is to keep to itself while it is tried.

#ifndef BAOCODE_APP_IDENTITY_H_
#define BAOCODE_APP_IDENTITY_H_

#include <string>

// The environment variable that tells this copy of the app apart from
// another one of the same program.
extern const wchar_t* const kAppIdVariable;

// The product this build is, as its executable's name says: "claude" for
// baocode-claude.exe, "codex" for baocode-codex.exe, empty for a name that
// belongs to no product.
std::wstring ProductSuffix();

// This copy's id: the environment's, empty when it is not set.
std::wstring AppId();

// The window class this copy's windows have: the runner's own, with the
// product and then the id added to it when there are any. The same for
// the whole run.
const wchar_t* AppWindowClass();

// The title this copy's windows carry: the product's name ("BaoCode Claude",
// "BaoCode Codex"), with the id added to it when there is one
// ("BaoCode Claude (dev)").
std::wstring AppWindowTitle();

// The key Windows keeps this product's own settings under: the window's
// frame, the folder the logs go in. Each product has one of its own, so
// that the two do not write over each other's. The Claude Code product
// keeps the key it always had, though its name changed.
std::wstring SettingsKey();

// The mutex a running copy holds, so that a second one hands its paths to
// the first: each product's own, for the same reason.
std::wstring SingleInstanceName();

#endif  // BAOCODE_APP_IDENTITY_H_
