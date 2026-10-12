#!/usr/bin/env swift
// Register VietTelex Dev and request enabling its input mode for the current user.
// macOS may still require adding it through System Settings.

import Carbon
import Foundation

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: enable-dev-input-source.swift <app-path> <bundle-id> <input-source-id>\n".utf8))
    exit(2)
}

let appURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let bundleID = CommandLine.arguments[2]
let inputSourceID = CommandLine.arguments[3]

guard let appBundle = Bundle(url: appURL as URL), appBundle.bundleIdentifier == bundleID else {
    FileHandle.standardError.write(Data("App at \(appURL) does not have bundle ID \(bundleID)\n".utf8))
    exit(1)
}

let registrationStatus = TISRegisterInputSource(appURL)
guard registrationStatus == noErr else {
    FileHandle.standardError.write(Data("TISRegisterInputSource failed: \(registrationStatus)\n".utf8))
    exit(1)
}

func sourceID(_ source: TISInputSource) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

func installedSources() -> [TISInputSource]? {
    TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]
}

func findSource(withID id: String, in sources: [TISInputSource]) -> TISInputSource? {
    sources.first { sourceID($0) == id }
}

func isEnabled(_ source: TISInputSource) -> Bool? {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else {
        return nil
    }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
}

guard let installed = installedSources() else {
    FileHandle.standardError.write(Data("Could not enumerate installed input sources.\n".utf8))
    exit(1)
}

// Input modes cannot be selected while their parent input method is disabled.
guard let inputMethod = findSource(withID: bundleID, in: installed) else {
    FileHandle.standardError.write(Data("Dev bundle is missing input method: \(bundleID)\n".utf8))
    exit(1)
}

let inputMethodStatus = TISEnableInputSource(inputMethod)
if inputMethodStatus != noErr {
    FileHandle.standardError.write(Data("TISEnableInputSource was not accepted for input method \(bundleID): \(inputMethodStatus)\n".utf8))
}

guard let afterEnablingInputMethod = installedSources(),
      let source = findSource(withID: inputSourceID, in: afterEnablingInputMethod) else {
    FileHandle.standardError.write(Data("Dev bundle is missing input source: \(inputSourceID)\n".utf8))
    exit(1)
}

let status = TISEnableInputSource(source)
if status != noErr {
    FileHandle.standardError.write(Data("TISEnableInputSource was not accepted for input mode \(inputSourceID): \(status)\n".utf8))
}

guard let verifiedSources = installedSources(),
      let verifiedInputMethod = findSource(withID: bundleID, in: verifiedSources),
      let verifiedMode = findSource(withID: inputSourceID, in: verifiedSources) else {
    FileHandle.standardError.write(Data("Could not verify registered Dev input source state.\n".utf8))
    exit(1)
}

let inputMethodEnabled = isEnabled(verifiedInputMethod) == true
let modeEnabled = isEnabled(verifiedMode) == true
if !inputMethodEnabled || !modeEnabled {
    FileHandle.standardError.write(Data("Dev was registered, but macOS did not enable all of its input sources (input method enabled: \(inputMethodEnabled), mode enabled: \(modeEnabled)). The mode may not appear or be selectable until it is added in Keyboard → Text Input → Input Sources; if it is missing there, log out and back in.\n".utf8))
} else {
    print("Enabled input method: \(bundleID)")
    print("Enabled input source: \(inputSourceID)")
}

print("Registered input method: \(bundleID)")
print("Registered input source: \(inputSourceID)")
