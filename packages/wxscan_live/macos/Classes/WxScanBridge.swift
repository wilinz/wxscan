import Foundation

/// Thin wrapper over the wxscan C ABI.
///
/// The entry points are resolved at run time through ``WxScanNative``, because
/// the library is a Dart code asset rather than something this plugin links.
///
/// The C ABI returns plain structs; turning them into something a method
/// channel can carry belongs here, in the binding layer. The document produced
/// by ``scanFrame(_:bytes:width:height:rowStride:rotation:mirror:)`` matches
/// the one the Android binding produces, so the Dart side parses one shape.
enum WxScanBridge {
    /// Creates a scanner from model bytes. Passing nil for both selects the
    /// mode without models, which still decodes but detects small or distant
    /// symbols less reliably. Returns 0 if a model fails to load.
    static func create(detect: Data?, sr: Data?) -> Int {
        func withBytes<T>(_ data: Data?, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
            guard let data, !data.isEmpty else { return body(nil, 0) }
            return data.withUnsafeBytes { raw in
                body(raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        }
        guard let scannerNew = WxScanNative.scannerNew else { return 0 }
        return withBytes(detect) { d, dn in
            withBytes(sr) { s, sn in
                scannerNew(d, dn, s, sn)
            }
        }
    }

    /// Creates a scanner from weight files on disk.
    ///
    /// The library reads them, so a megabyte of weights never crosses the
    /// method channel. A nil path means that network is absent, as nil data is
    /// to `create`.
    ///
    /// Returns 0 when a path cannot be read or is not weights, having logged
    /// which of the two it was — that is the one thing the caller needs in
    /// order to fix it, and the one thing a handle of zero cannot carry.
    static func create(detectPath: String?, srPath: String?) -> Int {
        guard let scannerNewPath = WxScanNative.scannerNewPath else { return 0 }
        var status: Int32 = 0
        let id = withOptionalCString(detectPath) { d in
            withOptionalCString(srPath) { s in
                scannerNewPath(d, s, &status)
            }
        }
        if id == 0 {
            let why: String
            switch status {
            case 1: why = "a path is not valid text"
            case 2: why = "a file could not be read"
            case 4: why = "a file was read but is not weights this build can load"
            default: why = "the scanner could not be created"
            }
            NSLog("wxscan: \(why) — detect=\(detectPath ?? "nil") sr=\(srPath ?? "nil")")
        }
        return id
    }

    /// A Swift string as a C string for the duration of `body`, or NULL for nil.
    private static func withOptionalCString<T>(
        _ s: String?, _ body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        guard let s else { return body(nil) }
        return s.withCString { body($0) }
    }

    /// Takes a reference to a scanner this side did not create, so that it
    /// stays alive for as long as this side needs it.
    ///
    /// Returns the same handle, or 0 if it names no scanner — which is what a
    /// handle left over from a previous Dart isolate looks like after a hot
    /// restart.
    static func retain(_ scanner: Int) -> Int {
        guard scanner != 0, let retain = WxScanNative.scannerRetain else { return 0 }
        return retain(scanner)
    }

    /// Gives a handle back. The scanner goes when its last holder does.
    static func release(_ scanner: Int) {
        guard scanner != 0, let release = WxScanNative.scannerRelease else { return }
        release(scanner)
    }

    /// Whether the scanner has its detector network loaded.
    ///
    /// Worth asking rather than inferring for a scanner this side was lent: it
    /// was built elsewhere, from weights this side never saw.
    static func hasDetector(_ scanner: Int) -> Bool {
        guard scanner != 0, let has = WxScanNative.hasDetector else { return false }
        return has(scanner) != 0
    }

    /// Scans one frame and serializes the outcome.
    ///
    /// - Parameters:
    ///   - bytes: the Y plane, `rowStride` bytes per row.
    ///   - rotation: clockwise degrees needed to bring the frame upright.
    ///   - mirror: mirrors the returned x coordinates; the frame itself is
    ///     never mirrored, because the detector is trained on unmirrored input.
    /// - Returns: a JSON document, or the empty-frame document on failure.
    static func scanFrame(
        _ scanner: Int,
        bytes: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        rowStride: Int,
        rotation: Int32,
        mirror: Bool
    ) -> String {
        guard scanner != 0,
              let scanFrame = WxScanNative.scanFrame,
              let out = scanFrame(
                  scanner,
                  bytes,
                  Int32(width),
                  Int32(height),
                  Int32(rowStride),
                  rotation,
                  mirror ? 1 : 0
              )
        else { return emptyJson }
        defer { WxScanNative.resultsFree?(out) }
        return json(from: out.pointee)
    }

    /// The document for a frame with nothing in it, also used on failure.
    static let emptyJson = #"{"w":0,"h":0,"results":[],"candidates":[]}"#

    private static func json(from results: WxScanResults) -> String {
        var items: [[String: Any]] = []
        if let base = results.results {
            for i in 0 ..< Int(results.results_len) {
                let r = base[i]
                items.append([
                    "text": string(r.text),
                    "charset": string(r.charset),
                    "version": Int(r.qrcode_version),
                    "ecLevel": string(r.ec_level),
                    "charsetMode": string(r.charset_mode),
                    "binaryMethod": Int(r.binary_method),
                    "points": corners(r),
                ])
            }
        }

        var candidates: [[Double]] = []
        if let quads = results.candidates {
            for i in 0 ..< Int(results.candidates_len) {
                candidates.append((0 ..< 8).map { Double(quads[i * 8 + $0]) })
            }
        }

        let payload: [String: Any] = [
            "w": Int(results.width),
            "h": Int(results.height),
            "results": items,
            "candidates": candidates,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return emptyJson }
        return text
    }

    /// The eight corner values, which C exposes as a fixed-size array and
    /// Swift imports as a tuple.
    private static func corners(_ r: WxScanResult) -> [Double] {
        var points = r.points
        return withUnsafeBytes(of: &points) { raw in
            raw.bindMemory(to: Float.self).map(Double.init)
        }
    }

    private static func string(_ p: UnsafePointer<CChar>?) -> String {
        guard let p else { return "" }
        return String(cString: p)
    }
}
