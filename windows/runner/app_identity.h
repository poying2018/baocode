// The app's identity among the copies of it running at the same time: a
// development build and the installed one are the same program, and must
// not meet (the one would hand its paths to the other, see
// open_requests.cpp, and their windows would look alike in the taskbar).
//
// The environment variable that tells them apart is BAOCODE_APP_ID: the
// copy with an id ("dev", say) has its own window class and its own
// title. Without one, the class and the title are the ones of the app
// itself, so that the copies of the released app still find each other.

#ifndef BAOCODE_APP_IDENTITY_H_
#define BAOCODE_APP_IDENTITY_H_

#include <string>

// The environment variable that tells this copy of the app apart from
// another one of the same program.
extern const wchar_t* const kAppIdVariable;

// This copy's id: the environment's, empty when it is not set.
std::wstring AppId();

// The window class this copy's windows have: the runner's own, with the
// id added to it when there is one. The same for the whole run.
const wchar_t* AppWindowClass();

// The title this copy's windows carry: [product] itself, with the id
// added to it when there is one ("BaoCode (dev)").
std::wstring AppWindowTitle(const wchar_t* product);

#endif  // BAOCODE_APP_IDENTITY_H_
