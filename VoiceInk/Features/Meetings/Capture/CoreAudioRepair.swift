import Foundation
import IOKit

/// Helpers for a microphone that is present but delivers nothing.
enum CoreAudioRepair {
    /// True while the Mac's lid is shut. The built-in microphone does not work then.
    static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// Restarts the macOS audio service, the same as the `fixmic` shell alias. It only works once
    /// `allow-fixmic.sh` has been run, which lets this one command skip the password. Returns true when the command ran.
    static func restartCoreAudio() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/killall", "coreaudiod"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
