library file_picker;

// The hosted file_picker 8.x has no OpenHarmony implementation, and its
// Windows code needs win32 5.x while the OpenHarmony ports of the plus plugins
// need win32 6.x. This copy keeps the public API and the method-channel
// implementation (the protocol file_picker_ohos' native side speaks) and drops
// the desktop implementations.
export './src/file_picker.dart';
export './src/platform_file.dart';
export './src/file_picker_result.dart';
export './src/file_picker_io.dart';
