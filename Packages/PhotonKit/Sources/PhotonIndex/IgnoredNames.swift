/// What the scanner skips. Dot files cover AppleDouble `._` files, which exFAT volumes fill up with.
enum IgnoredNames {
    private static let directories: Set<String> = ["$recycle.bin", "system volume information", "found.000"]
    private static let bundleSuffixes = [".photoslibrary", ".app", ".aplibrary", ".fcpbundle", ".imovielibrary"]

    static func skips(_ name: String, isDirectory: Bool) -> Bool {
        if name.hasPrefix(".") { return true }
        guard isDirectory else { return false }
        let lowered = name.lowercased()
        return directories.contains(lowered) || bundleSuffixes.contains { lowered.hasSuffix($0) }
    }
}
