import Foundation

/// Mneme's version: one source for the command-line tool, the app bundle (Scripts/build-app.sh reads it from this
/// file), evaluation reports and transcript provenance. A release tag `vX.Y.Z` must match it (release workflow).
public enum MnemeVersion {
    public static let current = "0.1.0"
}

/// The machine a measurement was taken on. Recorded in evaluation reports, because speed and, to a lesser extent,
/// Core ML numerics depend on the chip and the operating system.
public struct PlatformInfo: Codable, Equatable, Sendable {
    /// For example "macOS 26.5.2".
    public var os: String
    /// For example "arm64".
    public var architecture: String
    /// Hardware model, for example "Mac16,1" ("VirtualMac2,1" on a hosted CI runner).
    public var machine: String?

    public init(os: String, architecture: String, machine: String?) {
        self.os = os
        self.architecture = architecture
        self.machine = machine
    }

    public static var current: PlatformInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let name = "macOS"
        #else
        let name = "iOS"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return PlatformInfo(
            os: "\(name) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: architecture,
            machine: hardwareModel()
        )
    }

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) }
        }
    }
}
