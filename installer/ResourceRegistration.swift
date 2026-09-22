import CryptoKit
import Foundation

/// Keeps each installed frontend paired with its own pre-registration resource.
/// Pending updates must not replace the backup for the currently running version.
enum ResourceRegistration {
    static func register(resourcePath: String, archivePath: String, backupDirectory: String) throws {
        let manager = FileManager.default
        let resource = URL(fileURLWithPath: resourcePath)
        let original = try Data(contentsOf: resource)
        let originalHash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let backups = URL(fileURLWithPath: backupDirectory, isDirectory: true)
        let previousBackup = backups.appendingPathComponent(originalHash + ".neu")
        let pristine: Data
        if manager.fileExists(atPath: previousBackup.path) {
            pristine = try Data(contentsOf: previousBackup)
        } else if original.range(of: Data("__yaaglD3MetalUpdate".utf8)) != nil {
            // Recover from the current frontend, never from an older unrelated backup.
            // Only our recognized updater hook and catalog entry are removed.
            let recovery = resource.deletingLastPathComponent().appendingPathComponent(".wine-recovery-\(UUID().uuidString).neu")
            defer { try? manager.removeItem(at: recovery) }
            try AsarPatcher.patch(sourcePath: resourcePath, outputPath: recovery.path,
                                  archivePath: archivePath, displayName: RuntimePackage.targetDisplayName,
                                  recoveringRegistration: true)
            pristine = try Data(contentsOf: recovery)
        } else {
            pristine = original
        }

        let staging = resource.deletingLastPathComponent().appendingPathComponent(".wine-registration-\(UUID().uuidString).neu")
        defer { try? manager.removeItem(at: staging) }
        try AsarPatcher.patch(sourcePath: resourcePath, outputPath: staging.path,
                              archivePath: archivePath, displayName: RuntimePackage.targetDisplayName)
        let patched = try Data(contentsOf: staging)
        let patchedHash = SHA256.hash(data: patched).map { String(format: "%02x", $0) }.joined()
        let backup = backups.appendingPathComponent(patchedHash + ".neu")
        try manager.createDirectory(at: backups, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: backup.path) {
            try pristine.write(to: backup, options: .atomic)
        }
        // Never publish a frontend for which restoring the same version is impossible.
        guard try Data(contentsOf: backup) == pristine else {
            throw NSError(domain: "Registration", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The Yaagl registration backup does not match this frontend. No resource was replaced."])
        }
        if patched != original {
            _ = try manager.replaceItemAt(resource, withItemAt: staging)
        }
    }

    /// Returns false when an upstream update already replaced our registered resource.
    @discardableResult
    static func restore(resourcePath: String, backupDirectory: String) throws -> Bool {
        let resource = URL(fileURLWithPath: resourcePath)
        let current = try Data(contentsOf: resource)
        let hash = SHA256.hash(data: current).map { String(format: "%02x", $0) }.joined()
        let backup = URL(fileURLWithPath: backupDirectory, isDirectory: true).appendingPathComponent(hash + ".neu")
        guard FileManager.default.fileExists(atPath: backup.path) else {
            guard current.range(of: Data("__yaaglD3MetalUpdate".utf8)) == nil else {
                throw NSError(domain: "Registration", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "Yaagl's registered frontend has changed. Restore cannot safely remove its update helper; the frontend and helper have been preserved."])
            }
            return false
        }
        let original = try Data(contentsOf: backup)
        guard original.range(of: Data("__yaaglD3MetalUpdate".utf8)) == nil else {
            throw NSError(domain: "Registration", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "The saved frontend still requires the registration helper. Restore was stopped without replacing it."])
        }
        try original.write(to: resource, options: .atomic)
        return true
    }
}
