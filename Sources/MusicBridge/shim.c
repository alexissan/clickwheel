// Intentionally empty.
//
// SwiftPM requires at least one compilable source file in a C target. The real
// content of this target is `include/Music.h`, the ScriptingBridge interface
// generated from Music.app's scripting definition:
//
//     sdef /System/Applications/Music.app | sdp -fh --basename Music -o include
//
// Regenerate it with `Scripts/regenerate_bridge.sh` if Music.app's dictionary
// changes in a future macOS release.
