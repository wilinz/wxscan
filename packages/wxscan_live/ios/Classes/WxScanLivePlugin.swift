import AVFoundation
import CoreImage
import Flutter
import UIKit

/// Preview texture: the CVPixelBuffer the camera gives is handed to Flutter as
/// it is, staying on the GPU with no pixel copying.
///
/// Flutter's iOS Texture takes BGRA or bi-planar YUV, and this uses the
/// latter: the capture format is already 420f, and its Y plane feeds the
/// scanner at no cost, without a second colour conversion.
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

/// Stream of preview sizes. A new subscriber gets the current value first,
/// and a rotation pushes the next one.
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
        // displayRotation is always 0: here the picture is brought upright on
        // the capture connection, so Dart needs no RotatedBox of its own,
        // which is what Android relies on instead (see WxPreviewSize).
        let map: [String: Any] = ["width": width, "height": height, "displayRotation": 0]
        last = map
        DispatchQueue.main.async { self.sink?(map) }
    }
}

/// AVFoundation captures frames and sends them straight into Rust over the C
/// ABI, without passing through Dart; the preview is a Flutter Texture.
///
/// The one difference from the Android implementation is *orientation*. There
/// the texture stays in the device's natural orientation and Dart makes up the
/// rotation; here the capture connection brings the picture upright, so the
/// rotation handed to Rust is always 0 and so is the displayRotation reported
/// back. The channel names, method names and JSON are identical on both.
public class WxScanLivePlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
    AVCaptureVideoDataOutputSampleBufferDelegate
{

    private var registrar: FlutterPluginRegistrar?
    private var textureRegistry: FlutterTextureRegistry?
    private var texture: WxScanTexture?
    private var textureId: Int64 = -1

    private var scanSink: FlutterEventSink?
    private let sizeStream = WxPreviewSizeStream()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?

    /// Counts taps, so that only the newest one's timer restores continuous
    /// focus. Touched on the main thread only.
    private var focusGeneration: UInt64 = 0

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
    /// Whether a preview texture exists and a session is meant to be running.
    ///
    /// Main-thread state, and it has to move with the texture rather than with
    /// the capture session: `stopRunning` and `startRunning` happen later on
    /// `sessionQueue`, and a caller that leaves the page and comes straight
    /// back must not be told the texture it just lost is still good.
    private var started = false

    /// Set between the start of setup and the texture being registered, both
    /// on the main thread. Two initialisations in that window would each build
    /// a session and register a texture, leaving the first registered and
    /// nothing drawing into it.
    private var starting = false

    /// Which camera session is open, or 0 when none is.
    ///
    /// The camera goes to whoever asked for it last, so "close the camera" is
    /// not a thing a caller can be trusted to mean about the camera *it*
    /// opened — by the time it says so, the camera may be someone else's. The
    /// number is minted on every open, handed to Dart, and sent back with the
    /// close; one that does not match is a caller closing a session that has
    /// already ended, and closes nothing.
    private var sessionId = 0
    private var lastSessionId = 0

    /// The shortSide the running session was configured with, to notice a
    /// takeover that asks for a different resolution.
    private var boundShortSide = 0

    /// The sensor's own size, landscape, so w > h.
    private var nativeW = 0
    private var nativeH = 0

    /// Short-side pixels of the capture resolution; 0 means the device's highest.
/// The default is 720 (see WxResolution on the Dart side).
    private var shortSide = 720

    /// A YUV copy of the most recent frame, for freezing the picture when several
/// codes are in view. It is already upright.
    private let lastFrameLock = NSLock()
    private var lastY: Data?
    private var lastUV: Data?
    private var lastFrameW = 0
    private var lastFrameH = 0

    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Crude timing: one line every 30 frames, to see the scan latency on a
    // real device.
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
        instance.registrar = registrar
        instance.textureRegistry = registrar.textures()

        let method = FlutterMethodChannel(name: "wxscan_live", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)

        let scan = FlutterEventChannel(name: "wxscan_live/scan", binaryMessenger: registrar.messenger())
        scan.setStreamHandler(instance)

        let size = FlutterEventChannel(name: "wxscan_live/preview_size", binaryMessenger: registrar.messenger())
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
                // `started` belongs to the main thread now; what this needs to
                // know is whether there is a configured session here to change,
                // which is this queue's own business.
                if self.session.isRunning {
                    self.applyResolution()
                    let (w, h) = self.currentPreviewSize()
                    self.sizeStream.push(width: w, height: h)
                }
                DispatchQueue.main.async { result(nil) }
            }
        case "setScanning":
            let on = (call.arguments as? [String: Any])?["value"] as? Bool ?? true
            sessionQueue.async { self.scanning = on }
            result(nil)
        case "setTorch":
            let on = (call.arguments as? [String: Any])?["value"] as? Bool ?? false
            setTorch(on, result: result)
        case "hasTorch":
            result(device?.hasTorch ?? false)
        case "grabFrame":
            scanQueue.async { let jpeg = self.grabJpeg(); DispatchQueue.main.async { result(jpeg) } }
        case "setZoom":
            let want = (call.arguments as? [String: Any])?["ratio"] as? Double ?? 1.0
            result(setZoom(want))
        case "focusAt":
            let args = call.arguments as? [String: Any]
            let x = args?["x"] as? Double ?? -1
            let y = args?["y"] as? Double ?? -1
            result(focusAt(x: x, y: y))
        case "zoomRange":
            result(zoomRange())
        case "selfTestNative":
            handleSelfTest(call, result: result)
        case "dispose":
            // Closing the camera is the one call that can be sent by someone
            // who no longer owns it: a controller that lost the camera to a
            // later one and is now being disposed. The session it names says
            // which, and a stale one closes nothing. Zero — a caller with no
            // session of its own — still closes, since that is the only way
            // anything can be closed by a caller that never opened it.
            let session = (call.arguments as? [String: Any])?["sessionId"] as? Int ?? 0
            if session == 0 || session == sessionId { teardown() }
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
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            result(FlutterError(
                code: "NO_PERMISSION",
                message: "camera permission not granted",
                details: nil
            ))
            return
        }
        // Already running, so this is a takeover: the camera goes to the
        // caller that asked last, and the one that had it is told by its own
        // Dart side. The session itself is not rebuilt — what changes hands
        // is the session number, the scanner, and the resolution, over the
        // capture session already running.
        //
        // A hot restart arrives here looking exactly like a second caller:
        // this plugin outlived the isolate and still holds the camera, while
        // everything Dart lent it is gone. Handing over is the answer to
        // both, which is why there is no attempt to tell them apart.
        if started {
            lastSessionId += 1
            sessionId = lastSessionId
            // The frames in flight are decoded with whatever this settles on;
            // the caller that had the camera is not reading them any more.
            ensureScanner(detect: detect, sr: sr, borrowed: borrowed)
            let resolutionChanged = shortSide != boundShortSide
            boundShortSide = shortSide
            if resolutionChanged {
                sessionQueue.async {
                    self.applyResolution()
                    let (w, h) = self.currentPreviewSize()
                    DispatchQueue.main.async { self.sizeStream.push(width: w, height: h) }
                }
            }
            let (w, h) = currentPreviewSize()
            result(infoMap(width: w, height: h))
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
            } catch {
                DispatchQueue.main.async {
                    self.starting = false
                    result(FlutterError(code: "INIT_ERROR", message: error.localizedDescription, details: nil))
                }
                return
            }

            DispatchQueue.main.async {
                // The page can be left again while the session is being built.
                // Teardown clears this, and there is then nothing to attach a
                // texture to.
                guard self.starting else {
                    result(FlutterError(
                        code: "CANCELLED",
                        message: "the camera was disposed while starting",
                        details: nil
                    ))
                    return
                }
                let tex = WxScanTexture()
                self.texture = tex
                self.textureId = self.textureRegistry?.register(tex) ?? -1
                guard self.textureId >= 0 else {
                    self.texture = nil
                    self.starting = false
                    result(FlutterError(
                        code: "NO_TEXTURE",
                        message: "the texture registry refused a texture",
                        details: nil
                    ))
                    return
                }
                // Both flags move here, with the texture they describe, and
                // before the result goes back: what Dart is handed and what a
                // second call sees have to agree.
                self.started = true
                self.starting = false
                // Minted here with them, and on the same thread: what Dart is
                // handed and what the next call reads have to agree.
                self.lastSessionId += 1
                self.sessionId = self.lastSessionId
                self.boundShortSide = self.shortSide

                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                NotificationCenter.default.addObserver(
                    self, selector: #selector(self.onOrientationChanged),
                    name: UIDevice.orientationDidChangeNotification, object: nil
                )
                self.applyOrientation()

                self.sessionQueue.async { self.session.startRunning() }

                let (w, h) = self.currentPreviewSize()
                self.sizeStream.push(width: w, height: h)
                result(self.infoMap(width: w, height: h))
            }
        }
    }

    private func infoMap(width: Int, height: Int) -> [String: Any] {
        [
            "textureId": textureId,
            "sessionId": sessionId,
            "previewWidth": width,
            "previewHeight": height,
            "displayRotation": 0,
            "nativeReady": WxScanNative.ping?() == 1,
            "modelsLoaded": modelsLoaded,
        ]
    }

    private func setupSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw err(1, "no back camera available") }
        device = dev

        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw err(2, "cannot attach the camera") }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        // Bi-planar YUV: the Y plane is already the grayscale image, so it
        // goes straight to Rust and saves a colour conversion.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(videoOutput) else { throw err(3, "cannot attach the capture output") }
        session.addOutput(videoOutput)


        // Focus near: scanning happens at 10 to 30 cm.
        if (try? dev.lockForConfiguration()) != nil {
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isAutoFocusRangeRestrictionSupported { dev.autoFocusRangeRestriction = .near }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            dev.unlockForConfiguration()
        }
    }

    /// Sets the capture resolution from the current step, [shortSide].
    ///
    /// Scan time is roughly proportional to the pixel count, and 720p is
    /// enough for everyday codes. Dense ones, high version with many small
    /// modules, simply will not come out without the pixels, which is why the
    /// step is left to the caller (WxResolution on the Dart side).
    private func applyResolution() {
        let preset: AVCaptureSession.Preset = switch shortSide {
        case 720: .hd1280x720
        case 1080: .hd1920x1080
        default: .hd4K3840x2160
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        session.commitConfiguration()

        if let dev = device {
            let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
            nativeW = Int(dims.width)
            nativeH = Int(dims.height)
        }
        NSLog("wxscan: capture %dx%d preset=%@", nativeW, nativeH, session.sessionPreset.rawValue)
    }

    // MARK: - Orientation

    /// The interface orientation. During a rotation interfaceOrientation only
    /// updates once the layout has settled, so watching the device orientation
    /// is a trigger and the angle itself is read here, on the same reasoning
    /// as uiRotation() on Android.
    private func interfaceOrientation() -> UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.interfaceOrientation ?? .portrait
    }

    @objc private func onOrientationChanged() {
        // Read after the interface has finished turning, or the reading
        // catches an intermediate state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.applyOrientation()
            let (w, h) = self.currentPreviewSize()
            self.sizeStream.push(width: w, height: h)
        }
    }

    /// Brings the picture upright on the capture connection. After that a
    /// frame is what the screen shows, so the scan coordinates and the preview
    /// share one frame of reference for free and Rust has nothing to rotate
    /// (it is passed a rotation of 0).
    /// How far the connection turns the buffer to bring the picture upright.
    ///
    /// Shared with [focusAt], which has to turn a point back the other way:
    /// focusPointOfInterest is in the buffer's own coordinates and knows
    /// nothing of the rotation applied downstream of it.
    private func uprightRotation() -> CGFloat {
        switch interfaceOrientation() {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        default: return 90
        }
    }

    private func applyOrientation() {
        guard let conn = videoOutput.connection(with: .video) else { return }
        let o = interfaceOrientation()
        if #available(iOS 17.0, *) {
            let angle = uprightRotation()
            if conn.isVideoRotationAngleSupported(angle), conn.videoRotationAngle != angle {
                conn.videoRotationAngle = angle
            }
        } else {
            let vo: AVCaptureVideoOrientation
            switch o {
            case .portrait: vo = .portrait
            case .portraitUpsideDown: vo = .portraitUpsideDown
            case .landscapeLeft: vo = .landscapeLeft
            case .landscapeRight: vo = .landscapeRight
            default: vo = .portrait
            }
            if conn.isVideoOrientationSupported, conn.videoOrientation != vo {
                conn.videoOrientation = vo
            }
        }
    }

    /// The size of the picture once upright: in portrait the long side is
    /// vertical.
    private func currentPreviewSize() -> (Int, Int) {
        let long = max(nativeW, nativeH)
        let short = min(nativeW, nativeH)
        switch interfaceOrientation() {
        case .landscapeLeft, .landscapeRight: return (long, short)
        default: return (short, long)
        }
    }

    // MARK: - Per frame

    public func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from _: AVCaptureConnection)
    {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        texture?.update(pixels)
        let tid = textureId
        if tid >= 0 {
            DispatchQueue.main.async { [weak self] in self?.textureRegistry?.textureFrameAvailable(tid) }
        }

        guard scanning, !busy else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }

        let w = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        // The camera's buffer can be reclaimed at any moment and scanning is
        // asynchronous, so a copy has to be taken first (the Y plane of 720p
        // is about 900 KB).
        let y = Data(bytes: yBase, count: stride * h)

        // Keep a copy with chroma while we are here: with several codes in
        // view the picture is frozen for the user to choose from, and this is
        // the frame that gets frozen.
        if CVPixelBufferGetPlaneCount(pixels) > 1,
           let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)
        {
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
            let uvH = CVPixelBufferGetHeightOfPlane(pixels, 1)
            let uv = Data(bytes: uvBase, count: uvStride * uvH)
            // The Y copy carries its stride, and freezing reads it row by
            // row by that stride, so the size is stored alongside.
            lastFrameLock.lock()
            lastY = y; lastUV = uv; lastFrameW = w; lastFrameH = h
            lastFrameLock.unlock()
        }

        busy = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            let json: String = y.withUnsafeBytes { raw -> String in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return "" }
                // The back camera shows what the eye sees, so the coordinates
                // are not flipped.
                return WxScanBridge.scanFrame(
                    self.scanner, bytes: base, width: w, height: h,
                    rowStride: stride, rotation: 0, mirror: false
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

    /// Compresses the buffered frame to JPEG. It was brought upright at
    /// capture and its size matches the analysis frame, so Dart can draw its
    /// markers in one set of coordinates.
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

    // MARK: - Torch and zoom

    private func setTorch(_ on: Bool, result: @escaping FlutterResult) {
        guard let dev = device, dev.hasTorch else { result(nil); return }
        do {
            try dev.lockForConfiguration()
            dev.torchMode = on ? .on : .off
            dev.unlockForConfiguration()
            result(nil)
        } catch {
            result(FlutterError(code: "TORCH_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func setZoom(_ want: Double) -> Double {
        guard let dev = device else { return 1.0 }
        let lo = Double(dev.minAvailableVideoZoomFactor)
        let hi = Double(dev.maxAvailableVideoZoomFactor)
        let clamped = min(max(want, lo), hi)
        do {
            try dev.lockForConfiguration()
            dev.videoZoomFactor = CGFloat(clamped)
            dev.unlockForConfiguration()
            return clamped
        } catch {
            return Double(dev.videoZoomFactor)
        }
    }

    /// Focuses and meters on one point of the upright picture, given as
    /// fractions of its width and height.
    ///
    /// `focusPointOfInterest` is in the coordinates of the buffer the camera
    /// writes. The connection turns that buffer *clockwise* by
    /// [uprightRotation] to stand the picture up, so a point comes back the
    /// other way: undoing 90 sends (x, y) to (y, 1 - x), and round from there.
    /// Turning it the wrong way lands on the diagonally opposite point, which
    /// is what the first attempt here did — the two 90s are not symmetric and
    /// only a device settles which is which.
    ///
    /// Exposure follows the same point, which is what a tap on a camera means
    /// everywhere. Both are left in their auto — not continuous — modes, and
    /// [restoreContinuousFocus] puts them back a few seconds later, so a
    /// scanner nobody is tapping goes on focusing by itself.
    private func focusAt(x: Double, y: Double) -> Bool {
        guard x >= 0, x <= 1, y >= 0, y <= 1, let dev = device else { return false }
        let canFocus = dev.isFocusPointOfInterestSupported && dev.isFocusModeSupported(.autoFocus)
        let canExpose = dev.isExposurePointOfInterestSupported
            && dev.isExposureModeSupported(.autoExpose)
        if !canFocus && !canExpose { return false }

        let p: CGPoint
        switch Int(uprightRotation()) {
        case 90: p = CGPoint(x: y, y: 1 - x)
        case 180: p = CGPoint(x: 1 - x, y: 1 - y)
        case 270: p = CGPoint(x: 1 - y, y: x)
        default: p = CGPoint(x: x, y: y)
        }

        do {
            try dev.lockForConfiguration()
            if canFocus {
                dev.focusPointOfInterest = p
                dev.focusMode = .autoFocus
            }
            if canExpose {
                dev.exposurePointOfInterest = p
                dev.exposureMode = .autoExpose
            }
            dev.unlockForConfiguration()
        } catch {
            return false
        }
        restoreContinuousFocus()
        return true
    }

    /// Hands the camera back to itself once the tap has had its moment.
    ///
    /// Only the last tap's timer does anything: an earlier one firing would
    /// cut short the focus the reader just asked for.
    private func restoreContinuousFocus() {
        focusGeneration &+= 1
        let mine = focusGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.focusGeneration == mine, let dev = self.device else { return }
            guard (try? dev.lockForConfiguration()) != nil else { return }
            if dev.isFocusModeSupported(.continuousAutoFocus) {
                dev.focusMode = .continuousAutoFocus
            }
            if dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposureMode = .continuousAutoExposure
            }
            dev.unlockForConfiguration()
        }
    }

    private func zoomRange() -> [String: Double] {
        guard let dev = device else { return ["min": 1, "max": 1, "current": 1] }
        return [
            "min": Double(dev.minAvailableVideoZoomFactor),
            "max": Double(dev.maxAvailableVideoZoomFactor),
            "current": Double(dev.videoZoomFactor),
        ]
    }

    // MARK: - Self test

    /// Takes exactly the path a camera frame takes, a grayscale image with
    /// row padding through the C ABI, to confirm on a real device that the
    /// stretch from Swift to Rust works.
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
        // Whatever was held is given back first, unconditionally. Only the
        // caller that is about to own the camera reaches this — the ones that
        // failed, and the one that found a session being built, have returned
        // already — so a scanner left over from before belongs to nobody that
        // is still reading frames. Keeping it would decode the new owner's
        // frames with weights it never asked for, and report the previous
        // scanner's `modelsLoaded` as if it were this one's.
        //
        // Left over from what: the caller that just lost the camera to this
        // one, a hot restart, which leaves this plugin running while
        // everything it was lent goes away, or an initialize that settled a
        // scanner and then failed to configure a session.
        //
        // The session may be running while this swaps the handle out, on a
        // takeover. The scan callback reads the field per frame, and the one
        // frame that could read the gap between the release and the retain
        // reads a zero, which names no scanner and is refused by the library
        // rather than followed. The release itself is queued behind whatever
        // frame is in flight on the scan queue, so no frame is decoding
        // against the handle being given back.
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
        // Never reused: the ids only go up, so a close that arrives late names
        // a session that has ended rather than the next one.
        sessionId = 0
        boundShortSide = 0
        releaseScanner()
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()

        // With the texture, on the main thread: leaving this to the block
        // below meant a page re-entered before `stopRunning` had returned took
        // the "already running" path and was handed the texture id -1 that
        // this line had just written, which draws nothing and starts nothing.
        started = false
        starting = false

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
            self.busy = false
            self.lastFrameLock.lock()
            self.lastY = nil; self.lastUV = nil
            self.lastFrameLock.unlock()
        }
    }

    private func err(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "wxscan_live", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
