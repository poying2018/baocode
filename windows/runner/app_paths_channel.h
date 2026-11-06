// The paths Flutter asks Windows for, over `baocode/app_paths`. The
// browser bridge needs one the native messaging host can resolve too,
// without depending on the TEMP or TMP each process inherited.

#ifndef RUNNER_APP_PATHS_CHANNEL_H_
#define RUNNER_APP_PATHS_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Answers the channel on |messenger| for as long as the channel is kept.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> ListenAppPaths(
    flutter::BinaryMessenger* messenger);

#endif  // RUNNER_APP_PATHS_CHANNEL_H_
