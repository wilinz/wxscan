import Foundation

/// Resolves the scanner's C entry points at run time.
///
/// The library is not linked into this plugin. It is a Dart code asset, built
/// and bundled by the `wxscan_core` package's build hook, which means the Dart
/// runtime owns it and Xcode never sees it at link time. Looking the symbols up
/// with `dlsym` is what lets the camera path share that one copy instead of
/// building and shipping a second one.
///
/// The types still come from `wxscan.h`; only the functions are resolved here.
enum WxScanNative {
    typealias ScannerNew = @convention(c) (
        UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int
    ) -> OpaquePointer?
    typealias ScannerFree = @convention(c) (OpaquePointer?) -> Void
    typealias SetScaleFactor = @convention(c) (OpaquePointer?, Float) -> Void
    typealias ScanFrame = @convention(c) (
        OpaquePointer?, UnsafePointer<UInt8>?, Int32, Int32, Int32, Int32, Int32
    ) -> UnsafeMutablePointer<WxScanResults>?
    typealias ResultsFree = @convention(c) (UnsafeMutablePointer<WxScanResults>?) -> Void
    typealias Ping = @convention(c) () -> Int32

    /// Whether the library was found. False leaves the plugin in its
    /// no-scanner mode rather than crashing.
    static var isAvailable: Bool { handle != nil }

    static let scannerNew: ScannerNew? = symbol("wxscan_scanner_new")
    static let scannerFree: ScannerFree? = symbol("wxscan_scanner_free")
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
            "wxscan_core.framework/Versions/A/wxscan_core",
            "wxscan_core.framework/wxscan_core",
        ]
        var candidates = relative.map { "@rpath/\($0)" }
        if let frameworks = Bundle.main.privateFrameworksURL?.path {
            candidates = relative.map { "\(frameworks)/\($0)" } + candidates
        }
        for path in candidates {
            if let h = dlopen(path, RTLD_LAZY) { return h }
        }
        NSLog("wxscan: the wxscan_core code asset is not in this bundle; "
            + "add the wxscan_core package as a dependency")
        return nil
    }()

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
