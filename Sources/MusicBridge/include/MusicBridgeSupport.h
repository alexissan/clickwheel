/*
 * MusicBridgeSupport.h
 *
 * Typed element accessors for Music.app's ScriptingBridge collections.
 *
 * Why this file exists: `Music.h` only *declares* its classes. Scripting
 * Bridge synthesises them at runtime with `objc_allocateClassPair`, so there
 * is no `_OBJC_CLASS_$_MusicTrack` symbol to link against. In Objective-C that
 * is a non-issue because `(MusicTrack *)obj` is a compile-time pointer cast.
 * Swift's `as?`, however, lowers to `swift_dynamicCastObjCClass`, which needs
 * the class object and therefore fails to link.
 *
 * These inline casts happen on the C side where they cost nothing, and hand
 * Swift an already-typed pointer. Do not "simplify" them back into Swift
 * casts — the link error returns.
 */

#import <ScriptingBridge/ScriptingBridge.h>
#import "Music.h"

NS_ASSUME_NONNULL_BEGIN

/// Connects to Music.app and returns its scripting root, already typed.
///
/// Note this does *not* launch Music.app: `SBApplication` connects lazily and
/// only sends the first Apple event when a property is actually read.
static inline MusicApplication *_Nullable MBMusicApplication(NSString *bundleIdentifier) {
    return (MusicApplication *)[SBApplication applicationWithBundleIdentifier:bundleIdentifier];
}

static inline MusicPlaylist *_Nullable MBPlaylistAt(SBElementArray *array, NSInteger index) {
    if (index < 0 || index >= (NSInteger)array.count) { return nil; }
    return (MusicPlaylist *)[array objectAtIndex:(NSUInteger)index];
}

static inline MusicTrack *_Nullable MBTrackAt(SBElementArray *array, NSInteger index) {
    if (index < 0 || index >= (NSInteger)array.count) { return nil; }
    return (MusicTrack *)[array objectAtIndex:(NSUInteger)index];
}

static inline MusicArtwork *_Nullable MBArtworkAt(SBElementArray *array, NSInteger index) {
    if (index < 0 || index >= (NSInteger)array.count) { return nil; }
    return (MusicArtwork *)[array objectAtIndex:(NSUInteger)index];
}

NS_ASSUME_NONNULL_END
