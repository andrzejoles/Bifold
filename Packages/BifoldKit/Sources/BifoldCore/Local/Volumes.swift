import Foundation

/// Lista woluminów, wolne miejsce, wysuwanie.
public enum Volumes {
    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeTypeNameKey, .volumeURLKey,
    ]

    public static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { try? info(volumeURL: $0) }
    }

    public static func info(for path: VFSPath) throws -> VolumeInfo {
        guard let url = path.url else { throw VFSError.unsupported("volume info") }
        let volumeURL = (try? url.resourceValues(forKeys: [.volumeURLKey]).volume) ?? URL(filePath: "/")
        return try info(volumeURL: volumeURL)
    }

    static func info(volumeURL: URL) throws -> VolumeInfo {
        let v = try volumeURL.resourceValues(forKeys: Set(keys))
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0
        let available = max(important, Int64(v.volumeAvailableCapacity ?? 0))
        return VolumeInfo(
            path: .local(volumeURL),
            name: v.volumeLocalizedName ?? v.volumeName ?? volumeURL.lastPathComponent,
            totalCapacity: Int64(v.volumeTotalCapacity ?? 0),
            availableCapacity: available,
            fileSystem: v.volumeTypeName ?? "",
            isRemovable: v.volumeIsRemovable ?? false,
            isEjectable: v.volumeIsEjectable ?? false,
            isInternal: v.volumeIsInternal ?? false,
            isNetwork: !(v.volumeIsLocal ?? true),
            isReadOnly: v.volumeIsReadOnly ?? false
        )
    }

    /// Odmontowuje i (jeśli to możliwe) wysuwa wolumin.
    public static func eject(_ volume: VFSPath) async throws {
        guard let url = volume.url else { throw VFSError.unsupported("eject") }
        do {
            try await FileManager.default.unmountVolume(at: url, options: [.allPartitionsAndEjectDisk])
        } catch {
            throw VFSError.from(error, path: volume)
        }
    }
}
