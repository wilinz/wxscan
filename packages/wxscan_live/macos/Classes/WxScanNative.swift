import Foundation

/// Resolves the scanner's C entry points at run time.
///
/// The library is not linked into this plugin. It is a Dart code asset, built
/// and bundled by the `wxscan` package's build hook, which means the Dart
/// runtime owns it and Xcode never sees it at link time. Looking the symbols up
/// with `dlsym` is what lets the camera path share that one copy instead of
/// building and shipping a second one.
///
/// The types still come from `wxscan.h`; only the functions are resolved here.
///
/// A scanner is an `Int` here rather than a pointer because that is what it is:
/// `WxScanScannerId` is a handle the library looks up in a table of its own, so
/// one that has been released is refused rather than followed. That is what
/// makes it safe for this plugin to be handed a scanner Dart created.
enum WxScanNative {
    typealias ScannerNew = @convention(c) (
        UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int
    ) -> Int
    /// The path form. Its status out-parameter says which of the three ways a
    /// path can be wrong it was: 1 not text, 2 unreadable, 4 read but not
    /// weights this build can load.
    typealias ScannerNewPath = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?
    ) -> Int
    typealias ScannerRetain = @convention(c) (Int) -> Int
    typealias ScannerRelease = @convention(c) (Int) -> Void
    typealias HasDetector = @convention(c) (Int) -> Int32
    typealias SetScaleFactor = @convention(c) (Int, Float) -> Void
    typealias ScanFrame = @convention(c) (
        Int, UnsafePointer<UInt8>?, Int32, Int32, Int32, Int32, Int32
    ) -> UnsafeMutablePointer<WxScanResults>?
    typealias ResultsFree = @convention(c) (UnsafeMutablePointer<WxScanResults>?) -> Void
    typealias Ping = @convention(c) () -> Int32

    /// Whether the library was found. False leaves the plugin in its
    /// no-scanner mode rather than crashing.
    static var isAvailable: Bool { handle != nil }

    static let scannerNew: ScannerNew? = symbol("wxscan_scanner_new")
    static let scannerNewPath: ScannerNewPath? = symbol("wxscan_scanner_new_path")
    static let scannerRetain: ScannerRetain? = symbol("wxscan_scanner_retain")
    static let scannerRelease: ScannerRelease? = symbol("wxscan_scanner_release")
    static let hasDetector: HasDetector? = symbol("wxscan_scanner_has_detector")
    static let setScaleFactor: SetScaleFactor? = symbol("wxscan_scanner_set_scale_factor")
    static let scanFrame: ScanFrame? = symbol("wxscan_scan_frame")
    static let resultsFree: ResultsFree? = symbol("wxscan_results_free")
    static let ping: Ping? = symbol("wxscan_ping")

    /// The loaded image, or nil if the code asset is not in this bundle.
    ///
    /// `RTLD_DEFAULT` comes first: when Dart has already used the scanner the
    /// library is in the process, and re-opening it would be pointless work.
    private static let handle: UnsafeMutableRawPointer? = {
        if dlsym(UnsafeMutableRawPointer(bitPattern: -2), "wxscan_ping") != nil {
            return UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        }
        // Flutter bundles a code asset as a framework in the application's
        // private frameworks directory. The versioned path is the macOS
        // layout, the flat one is iOS's; the rpath forms are the fallback for
        // a host that lays the bundle out differently.
        let relative = [
            "wxscan.framework/Versions/A/wxscan",
            "wxscan.framework/wxscan",
        ]
        var candidates = relative.map { "@rpath/\($0)" }
        if let frameworks = Bundle.main.privateFrameworksURL?.path {
            candidates = relative.map { "\(frameworks)/\($0)" } + candidates
        }
        for path in candidates {
            if let h = dlopen(path, RTLD_LAZY) { return h }
        }
        NSLog("wxscan: the wxscan code asset is not in this bundle; "
            + "add the wxscan package as a dependency")
        return nil
    }()

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
