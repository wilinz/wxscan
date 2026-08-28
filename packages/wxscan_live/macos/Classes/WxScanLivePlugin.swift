import Accelerate
import AVFoundation
import Cocoa
import CoreImage
import FlutterMacOS

/// Preview texture: the CVPixelBuffer the camera gives is handed to Flutter as
/// it is, with no pixel copying.
final class WxScanTexture: NSObject, FlutterTexture {
    private var latest: CVPixelBuffer?
    private let lock = NSLock()

    func update(_ buffer: CVPixelBuffer) {
        lock.lock(); latest = buffer; lock.unlock()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock(); defer { lock.unlock() }
        guard let buf = latest else { return nil }
        return .passRetained(buf)
    }
}

/// Stream of preview sizes. A new subscriber gets the current value first.
final class WxPreviewSizeStream: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var last: [String: Any]?

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        if let l = last { events(l) }
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? { sink = nil; return nil }

    func push(width: Int, height: Int) {
        // The desktop does not rotate, so displayRotation is always 0.
        let map: [String: Any] = ["width": width, "height": height, "displayRotation": 0]
        last = map
        DispatchQueue.main.async { self.sink?(map) }
    }
}

/// AVFoundation captures frames and sends them straight into Rust over the C
/// ABI, without passing through Dart; the preview is a Flutter Texture.
///
/// The flow is the iOS one, minus the three things only a phone has: rotation,
/// torch and zoom. The corresponding methods are kept, so the channel protocol
/// matches on both sides, and report that there is none.
public class WxScanLivePlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
    AVCaptureVideoDataOutputSampleBufferDelegate
{
    private var textureRegistry: FlutterTextureRegistry?
    private var texture: WxScanTexture?
    private var textureId: Int64 = -1

    private var scanSink: FlutterEventSink?
    private let sizeStream = WxPreviewSizeStream()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?

    /// Camera callback queue: copies the pixels and dispatches, nothing else.
/// Scanning never runs here.
    private let sessionQueue = DispatchQueue(label: "com.wilinz.wxscanlive.session", qos: .userInitiated)
    /// Scan queue: runs Rust serially, dropping frames while busy.
    private let scanQueue = DispatchQueue(label: "com.wilinz.wxscanlive.scan", qos: .userInitiated)

    private var busy = false          // read and written on sessionQueue only
    private var scanning = true

    /// The scanner frames are decoded with, as the library's handle for it —
    /// a number it looks up in a table of its own, not an address. Zero is
    /// none.
    ///
    /// Built here unless Dart lent one it already holds, which is how an
    /// application scanning both live and from its photo library keeps a
    /// single set of weights in memory. Either way this side holds a reference
    /// of its own, so the scanner outlives whichever side lets go first.
    ///
    /// Written on the main thread and read on the scan queue, with no queue
    /// hop between the two, so the access is locked. Android's equivalent is
    /// `@Volatile` for the same reason. Without it a scan can read a handle
    /// released a moment earlier — which the handle table turns into a dropped
    /// frame rather than a use-after-free, but it is still a data race and
    /// still reported as one under the thread sanitiser.
    private let scannerLock = NSLock()
    private var _scanner: Int = 0
    private var scanner: Int {
        get {
            scannerLock.lock()
            defer { scannerLock.unlock() }
            return _scanner
        }
        set {
            scannerLock.lock()
            defer { scannerLock.unlock() }
            _scanner = newValue
        }
    }

    /// Whether the CNN models loaded. Without them decoding still works, but
    /// small or distant symbols are detected far less reliably.
    private var modelsLoaded = false
    private var started = false

    /// A start is under way but not finished.
    ///
    /// `started` does not become true until the session is configured and
    /// running, which leaves a window several hundred milliseconds wide in
    /// which a second initialize would pass the `started` check and configure
    /// a second session and register a second texture over the first. iOS has
    /// always had this; macOS reaches the same code by a different route,
    /// through the system permission prompt, and needs it just as much.
    private var starting = false

    private var frameW = 0
    private var frameH = 0

    /// Short-side pixels of the capture resolution; 0 means the device's highest.
/// The default is 720 (see WxResolution on the Dart side).
    private var shortSide = 720

    /// A YUV copy of the most recent frame, for freezing the picture when
    /// several codes are in view.
    private let lastFrameLock = NSLock()
    private var lastY: Data?
    private var lastUV: Data?
    private var lastFrameW = 0
    private var lastFrameH = 0

    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Output buffer pool for the horizontal flip (see mirrorFrame).
    private var flipPoolRef: CVPixelBufferPool?
    private var flipPoolW = 0
    private var flipPoolH = 0

    private var statFrames = 0
    private var statTotalMs = 0.0
    private var statMaxMs = 0.0

    // MARK: - Registration

    /// The engine is going away.
    ///
    /// Flutter calls this when the engine this plugin was registered with is
    /// destroyed — an add-to-app host tearing down a `FlutterEngine`, or one
    /// from a `FlutterEngineGroup`. Dart gets no chance to say `dispose`
    /// first, so without this the camera stays open and the reference this
    /// side holds on the scanner is never given back: the weights would sit in
    /// memory for the life of the process, once per engine.
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        teardown()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = WxScanLivePlugin()
        instance.textureRegistry = registrar.textures

        let method = FlutterMethodChannel(name: "wxscan_live", binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(instance, channel: method)

        let scan = FlutterEventChannel(name: "wxscan_live/scan", binaryMessenger: registrar.messenger)
        scan.setStreamHandler(instance)

        let size = FlutterEventChannel(name: "wxscan_live/preview_size", binaryMessenger: registrar.messenger)
        size.setStreamHandler(instance.sizeStream)
    }

    // MARK: - EventChannel (scan results)

    public func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        scanSink = events
        return nil
    }

    public func onCancel(withArguments _: Any?) -> FlutterError? {
        scanSink = nil
        return nil
    }

    // MARK: - MethodChannel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            let args = call.arguments as? [String: Any]
            if let want = args?["shortSide"] as? Int {
                shortSide = want
            }
            handleInitialize(
                detect: (args?["detectModel"] as? FlutterStandardTypedData)?.data,
                sr: (args?["srModel"] as? FlutterStandardTypedData)?.data,
                // A scanner Dart already holds, to be borrowed rather than
                // built. Absent means build one here.
                borrowed: (args?["scannerHandle"] as? NSNumber)?.intValue ?? 0,
                result: result
            )
        case "setResolution":
            let want = (call.arguments as? [String: Any])?["shortSide"] as? Int ?? 720
            sessionQueue.async {
                self.shortSide = want
                if self.started {
                    self.applyResolution()
                    self.sizeStream.push(width: self.frameW, height: self.frameH)
                }
                DispatchQueue.main.async { result(nil) }
            }
        case "setScanning":
            let on = (call.arguments as? [String: Any])?["value"] as? Bool ?? true
            sessionQueue.async { self.scanning = on }
            result(nil)
        // No torch and no zoom on the desktop: the methods are kept and
        // report that there is none.
        case "setTorch":
            result(nil)
        case "hasTorch":
            result(false)
        case "setZoom":
            result(1.0)
        case "zoomRange":
            result(["min": 1.0, "max": 1.0, "current": 1.0])
        case "grabFrame":
            scanQueue.async { let jpeg = self.grabJpeg(); DispatchQueue.main.async { result(jpeg) } }
        case "selfTestNative":
            handleSelfTest(call, result: result)
        case "dispose":
            teardown()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Initialisation

    private func handleInitialize(
        detect: Data?,
        sr: Data?,
        borrowed: Int,
        result: @escaping FlutterResult
    ) {
        // The scanner is settled last, once this call is known to be the one
        // that configures the camera. Doing it first meant a call that went on
        // to fail — no permission, or a camera already running — had already
        // swapped the scanner out from under whoever was using it.
        //
        // There is no permission_handler on the desktop, so permission is
        // asked for here: never asked means the system prompt, asked and
        // refused means an error straight back, and Dart points the user at
        // System Settings.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.handleInitialize(
                            detect: detect, sr: sr, borrowed: borrowed, result: result)
                    } else {
                        result(FlutterError(
                code: "NO_PERMISSION",
                message: "camera permission not granted",
                details: nil
            ))
                    }
                }
            }
            return
        default:
            result(FlutterError(
                code: "NO_PERMISSION",
                message: "camera permission not granted",
                details: nil
            ))
            return
        }
        // Already running: it keeps the scanner it has — the frames in flight
        // are being decoded with it.
        if started {
            result(infoMap())
            return
        }
        if starting {
            result(FlutterError(
                code: "BUSY",
                message: "the camera is already starting",
                details: nil
            ))
            return
        }
        ensureScanner(detect: detect, sr: sr, borrowed: borrowed)
        starting = true

        sessionQueue.async {
            do {
                try self.setupSession()
                // The resolution is set on its own, because it opens a
                // configuration transaction of its own that must not nest
                // inside setupSession's.
                self.applyResolution()
                self.disableMirroring()
            } catch {
                DispatchQueue.main.async {
                    self.starting = false
                    result(FlutterError(code: "INIT_ERROR", message: error.localizedDescription, details: nil))
                }
                return
            }

            DispatchQueue.main.async {
                let tex = WxScanTexture()
                self.texture = tex
                self.textureId = self.textureRegistry?.register(tex) ?? -1

                self.sessionQueue.async {
                    self.session.startRunning()
                    self.disableMirroring()
                    self.started = true
                    DispatchQueue.main.async { self.starting = false }
                }

                self.sizeStream.push(width: self.frameW, height: self.frameH)
                result(self.infoMap())
            }
        }
    }

    private func infoMap() -> [String: Any] {
        [
            "textureId": textureId,
            "previewWidth": frameW,
            "previewHeight": frameH,
            "displayRotation": 0,
            "nativeReady": WxScanNative.ping?() == 1,
            "modelsLoaded": modelsLoaded,
        ]
    }

    private func setupSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // The resolution is chosen by format (see selectFormat). macOS has no
        // .inputPriority as iOS does, but the device's activeFormat decides
        // anyway, so the preset is left at its default.

        guard let dev = AVCaptureDevice.default(for: .video) else { throw err(1, "no camera available") }
        device = dev

        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw err(2, "cannot attach the camera") }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        // The pixel format and the size are both set in applyResolution: the
        // Y plane of bi-planar YUV is already the grayscale image, so it goes
        // straight to Rust and saves a colour conversion.
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(videoOutput) else { throw err(3, "cannot attach the capture output") }
        session.addOutput(videoOutput)

    }

    /// Sets the capture resolution from the current step, [shortSide].
    ///
    /// A desktop camera gives 1080p or more by default, and scan time is
    /// roughly proportional to the pixel count: 42 ms a frame at 1080p, half
    /// that at 720p. Dense codes need the pixels to come out at all, so the
    /// step is left to the caller (WxResolution on the Dart side).
    ///
    /// Both places have to be set: activeFormat decides what the device
    /// captures, and the width and height in videoSettings decide what the
    /// data output emits. Setting only the former does nothing -- measured,
    /// the log said 720p and the frames were still 1080p.
    private func applyResolution() {
        guard let dev = device else { return }

        session.beginConfiguration()

        if let format = pickFormat(dev) {
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = format
                dev.unlockForConfiguration()
            } catch {
                NSLog("wxscan: could not select a capture format: %@", error.localizedDescription)
            }
        }

        // Measured: activeFormat and sessionPreset alone are not enough --
        // the log said 720p and the frames arriving were still 1080p. What
        // actually governs the data output's size is the width and height in
        // videoSettings, which macOS supports and iOS does not, so they are
        // stated explicitly here.
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        if shortSide > 0 {
            let d = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
            let scale = Double(shortSide) / Double(min(d.width, d.height))
            // Both even: the chroma planes of YUV are sampled 2x2.
            let w = (Int((Double(d.width) * scale).rounded()) / 2) * 2
            let h = (Int((Double(d.height) * scale).rounded()) / 2) * 2
            settings[kCVPixelBufferWidthKey as String] = w
            settings[kCVPixelBufferHeightKey as String] = h
        }
        videoOutput.videoSettings = settings

        session.commitConfiguration()

        // videoSettings decides the size, falling back to the device format's
        // when it says nothing.
        let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        frameW = (videoOutput.videoSettings[kCVPixelBufferWidthKey as String] as? Int) ?? Int(dims.width)
        frameH = (videoOutput.videoSettings[kCVPixelBufferHeightKey as String] as? Int) ?? Int(dims.height)
        NSLog("wxscan: capture %dx%d (device format %dx%d, %@)", frameW, frameH,
              dims.width, dims.height, dev.localizedName)
    }

    /// Picks a capture format: the largest whose short side does not exceed
    /// [shortSide], or simply the largest when shortSide is 0. Returns nil if
    /// none qualifies, the camera's lowest step being above what was asked,
    /// which leaves things as they are.
    private func pickFormat(_ dev: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestPixels = 0
        for f in dev.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let short = min(Int(d.width), Int(d.height))
            if shortSide > 0, short > shortSide { continue }
            let pixels = Int(d.width) * Int(d.height)
            if pixels > bestPixels {
                bestPixels = pixels
                best = f
            }
        }
        return best
    }

    /// Turns mirroring off on the capture connection, so what arrives is the
    /// *original* picture.
    ///
    /// The built-in Mac camera measures as having it off already (auto=false,
    /// mirrored=false): a hand moving right moves left in the picture, which
    /// is what the camera faithfully records. The comfortable mirror effect of
    /// FaceTime is added by the application. This adds it too, in
    /// [`mirrorFrame`], and adding it means first making sure nobody added it
    /// on our behalf.
    private func disableMirroring() {
        guard let conn = videoOutput.connection(with: .video), conn.isVideoMirroringSupported else { return }
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = false
    }

    /// Flips the frame horizontally into the mirror orientation, *for display
    /// only*: the preview texture and the frozen picture.
    ///
    /// The camera gives the original picture, where a hand moving right moves
    /// left. That looks wrong to the person in front of it, so it is flipped,
    /// as FaceTime and Photo Booth do. But *what goes to the scanner has to be
    /// the original frame*: the CNN detector is trained on normal orientation,
    /// and a mirrored frame only lowers the detection rate.
    ///
    /// The coordinates are reconciled by having Rust flip the ones it computes
    /// (`mirror_output` of `wxscan_scan_frame`). Everything Dart then sees --
    /// preview, markers, frozen picture, tap hit-testing -- is in the one
    /// mirrored coordinate system, with no flip to make up anywhere.
    ///
    /// vImage does the work, under 1 ms for a 720p frame, and the buffers come
    /// from a pool rather than being allocated per frame.
    private func mirrorFrame(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidthOfPlane(src, 0)
        let h = CVPixelBufferGetHeightOfPlane(src, 0)
        guard let pool = flipPool(width: w, height: h) else { return nil }

        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let dst = out else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        func plane(_ b: CVPixelBuffer, _ i: Int) -> vImage_Buffer? {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(b, i) else { return nil }
            return vImage_Buffer(data: base,
                                 height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(b, i)),
                                 width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(b, i)),
                                 rowBytes: CVPixelBufferGetBytesPerRowOfPlane(b, i))
        }

        // Luma plane: one byte per pixel, flipped as Planar8.
        guard var sy = plane(src, 0), var dy = plane(dst, 0),
              vImageHorizontalReflect_Planar8(&sy, &dy, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }

        // Chroma plane: CbCr interleaved, two bytes per "pixel". Flipping it
        // as Planar16U moves each CbCr pair as one indivisible unit, which is
        // exactly what is wanted.
        if CVPixelBufferGetPlaneCount(src) > 1, CVPixelBufferGetPlaneCount(dst) > 1 {
            guard var su = plane(src, 1), var du = plane(dst, 1),
                  vImageHorizontalReflect_Planar16U(&su, &du, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            else { return nil }
        }
        return dst
    }

    /// Buffer pool for the flip, rebuilt when the size changes because the
    /// resolution did.
    private func flipPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let p = flipPoolRef, flipPoolW == width, flipPoolH == height { return p }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess
        else { return nil }
        flipPoolRef = pool
        flipPoolW = width
        flipPoolH = height
        return pool
    }

    // MARK: - Per frame

    public func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from _: AVCaptureConnection)
    {
        guard let raw = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Display gets the mirrored frame, falling back to the original if
        // the flip fails, an odd-looking picture being better than none;
        // scanning gets the original.
        let shown = mirrorFrame(raw) ?? raw
        // Rust only has to flip the coordinates back if the flip succeeded.
        let mirrored = shown !== raw

        texture?.update(shown)
        let tid = textureId
        if tid >= 0 {
            DispatchQueue.main.async { [weak self] in self?.textureRegistry?.textureFrameAvailable(tid) }
        }

        guard scanning, !busy else { return }

        CVPixelBufferLockBaseAddress(raw, .readOnly)
        CVPixelBufferLockBaseAddress(shown, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(shown, .readOnly)
            CVPixelBufferUnlockBaseAddress(raw, .readOnly)
        }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(raw, 0) else { return }

        let w = CVPixelBufferGetWidthOfPlane(raw, 0)
        let h = CVPixelBufferGetHeightOfPlane(raw, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(raw, 0)
        // The camera's buffer can be reclaimed at any moment and scanning is
        // asynchronous, so a copy has to be taken first.
        let y = Data(bytes: yBase, count: stride * h)

        if frameW != w || frameH != h {
            frameW = w; frameH = h
            sizeStream.push(width: w, height: h)
        }

        // Keep a copy with chroma while we are here: with several codes in
        // view the picture is frozen for the user to choose from. That frozen
        // picture is for display, so the mirrored one is stored, sharing the
        // orientation of the preview and the markers.
        if CVPixelBufferGetPlaneCount(shown) > 1,
           let shownY = CVPixelBufferGetBaseAddressOfPlane(shown, 0),
           let uvBase = CVPixelBufferGetBaseAddressOfPlane(shown, 1)
        {
            let shownStride = CVPixelBufferGetBytesPerRowOfPlane(shown, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(shown, 1)
            let uvH = CVPixelBufferGetHeightOfPlane(shown, 1)
            lastFrameLock.lock()
            lastY = Data(bytes: shownY, count: shownStride * h)
            lastUV = Data(bytes: uvBase, count: uvStride * uvH)
            lastFrameW = w
            lastFrameH = h
            lastFrameLock.unlock()
        }

        busy = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            let json: String = y.withUnsafeBytes { raw -> String in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return "" }
                return WxScanBridge.scanFrame(
                    self.scanner, bytes: base, width: w, height: h,
                    rowStride: stride, rotation: 0, mirror: mirrored
                )
            }
            let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000

            self.statFrames += 1
            self.statTotalMs += dt
            self.statMaxMs = max(self.statMaxMs, dt)
            if self.statFrames >= 30 {
                let n = Double(self.statFrames)
                NSLog("wxscan: scan %.0fms avg / %.0fms max (%dx%d)",
                      self.statTotalMs / n, self.statMaxMs, w, h)
                self.statFrames = 0; self.statTotalMs = 0; self.statMaxMs = 0
            }

            self.sessionQueue.async { self.busy = false }
            if !json.isEmpty {
                DispatchQueue.main.async { self.scanSink?(json) }
            }
        }
    }

    // MARK: - Freezing the picture

    /// Compresses the buffered frame to JPEG. Its size matches the analysis
    /// frame, so Dart can draw its markers in one set of coordinates.
    private func grabJpeg() -> FlutterStandardTypedData? {
        lastFrameLock.lock()
        let y = lastY; let uv = lastUV
        let w = lastFrameW; let h = lastFrameH
        lastFrameLock.unlock()
        guard let y, let uv, w > 0, h > 0 else { return nil }

        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attrs as CFDictionary, &out) == kCVReturnSuccess,
              let buf = out else { return nil }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }

        // The source and destination row padding need not agree, so it is
        // copied row by row.
        let copyPlane = { (src: Data, plane: Int, rows: Int, bytesPerRow: Int) in
            guard let dst = CVPixelBufferGetBaseAddressOfPlane(buf, plane) else { return }
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(buf, plane)
            let srcStride = src.count / max(rows, 1)
            src.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for row in 0 ..< rows {
                    memcpy(dst.advanced(by: row * dstStride),
                           base.advanced(by: row * srcStride),
                           min(bytesPerRow, min(dstStride, srcStride)))
                }
            }
        }
        copyPlane(y, 0, h, w)
        copyPlane(uv, 1, h / 2, w)

        let image = CIImage(cvPixelBuffer: buf)
        guard let jpeg = ciContext.jpegRepresentation(
            of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88]
        ) else { return nil }
        return FlutterStandardTypedData(bytes: jpeg)
    }

    // MARK: - Self test

    /// Takes exactly the path a camera frame takes, a grayscale image with row
    /// padding through the C ABI, to confirm the stretch from Swift to Rust
    /// works.
    private func handleSelfTest(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        guard let gray = (args["gray"] as? FlutterStandardTypedData)?.data,
              let w = args["width"] as? Int, let h = args["height"] as? Int,
              w > 0, h > 0
        else {
            result(FlutterError(code: "BAD_ARGS", message: "missing grayscale data", details: nil))
            return
        }
        let rot = Int32(args["rotation"] as? Int ?? 0)

        scanQueue.async { [self] in
            // 16 bytes of row padding on purpose, to imitate the camera's
            // bytesPerRow.
            let stride = w + 16
            var padded = Data(count: stride * h)
            padded.withUnsafeMutableBytes { dst in
                gray.withUnsafeBytes { src in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let s = src.bindMemory(to: UInt8.self).baseAddress else { return }
                    for row in 0 ..< h {
                        memcpy(d.advanced(by: row * stride), s.advanced(by: row * w), w)
                    }
                }
            }
            let json = padded.withUnsafeBytes { raw -> String in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return "" }
                return WxScanBridge.scanFrame(
                    self.scanner, bytes: base, width: w, height: h,
                    rowStride: stride, rotation: rot, mirror: false
                )
            }
            NSLog("wxscan: selfTestNative rot=%d -> %@", rot, json)
            DispatchQueue.main.async { result(json) }
        }
    }

    // MARK: - Teardown

    /// Settles which scanner frames are decoded with.
    ///
    /// Dart may lend the handle of one it already holds — the same scanner an
    /// application uses for pictures from its photo library. Then there is one
    /// set of CNN weights in memory rather than two, and one set of thresholds
    /// that cannot drift apart. This side takes its own reference either way.
    ///
    /// Otherwise one is built here. A model that fails to load is not an
    /// error: the scanner falls back to the mode without models, which still
    /// decodes.
    private func ensureScanner(detect: Data?, sr: Data?, borrowed: Int) {
        // Whatever was held is given back first, unconditionally. By the time
        // this runs there is no camera running — the callers that only wanted
        // the state of one have already returned — so a scanner left over
        // from before belongs to nobody. Keeping it would decode this camera's
        // frames with weights the caller never asked for, and report the
        // previous scanner's `modelsLoaded` as if it were this one's.
        //
        // Left over from what: a hot restart, which leaves this plugin running
        // while everything it was lent goes away, or an initialize that
        // settled a scanner and then failed to configure a session.
        //
        // Releasing before retaining is safe even when it is the same scanner
        // twice over — but not for the reason the queueing suggests: the
        // queued release and the retain here run on different threads with no
        // ordering between them. What makes it safe is that a non-zero
        // `borrowed` can only come from a WxScanner Dart still holds, since
        // reading its handle after disposal throws. That reference outlives
        // both operations, so the count cannot reach zero in either order.
        releaseScanner()

        if borrowed != 0 {
            // A retain that comes back 0 means the handle names no scanner:
            // stale, from an isolate that is gone. Falling through and building
            // one here is better than a camera that decodes nothing.
            scanner = WxScanBridge.retain(borrowed)
            if scanner != 0 {
                // Built elsewhere, from weights this side never saw, so the
                // answer is asked for rather than inferred.
                modelsLoaded = WxScanBridge.hasDetector(scanner)
                return
            }
        }

        scanner = WxScanBridge.create(detect: detect, sr: sr)
        modelsLoaded = scanner != 0 && detect != nil
        if scanner == 0 {
            scanner = WxScanBridge.create(detect: nil, sr: nil)
        }
    }

    /// Gives back the reference this side holds, if it holds one.
    private func releaseScanner() {
        guard scanner != 0 else { return }
        // A frame may still be in flight on the scan queue naming this handle,
        // so the release goes to the back of that queue. It is only this
        // side's reference in any case: if Dart still holds the scanner,
        // nothing is freed here.
        let s = scanner
        scanner = 0
        modelsLoaded = false
        scanQueue.async { WxScanBridge.release(s) }
    }

    private func teardown() {
        releaseScanner()
        let tid = textureId
        textureId = -1
        if tid >= 0 { textureRegistry?.unregisterTexture(tid) }
        texture = nil

        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for i in self.session.inputs { self.session.removeInput(i) }
            for o in self.session.outputs { self.session.removeOutput(o) }
            self.session.commitConfiguration()
            self.device = nil
            self.started = false
            self.starting = false
            self.busy = false
            self.flipPoolRef = nil
            self.lastFrameLock.lock()
            self.lastY = nil; self.lastUV = nil
            self.lastFrameLock.unlock()
        }
    }

    private func err(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "wxscan_live", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
