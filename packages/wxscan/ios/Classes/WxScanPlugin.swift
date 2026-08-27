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
public class WxScanPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
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

    /// Camera callback queue: copies the pixels and dispatches, nothing else.
/// Scanning never runs here.
    private let sessionQueue = DispatchQueue(label: "com.wilinz.wxscan.session", qos: .userInitiated)
    /// Scan queue: runs Rust serially, dropping frames while busy.
    private let scanQueue = DispatchQueue(label: "com.wilinz.wxscan.scan", qos: .userInitiated)

    private var busy = false          // read and written on sessionQueue only
    private var scanning = true

    /// The native scanner. Owned here: this path never goes through Dart, so
    /// the plugin creates and releases its own instance rather than sharing one
    /// with the FFI bindings of wxscan_core.
    private var scanner: OpaquePointer?

    /// Whether the CNN models loaded. Without them decoding still works, but
    /// small or distant symbols are detected far less reliably.
    private var modelsLoaded = false
    private var started = false

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

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = WxScanPlugin()
        instance.registrar = registrar
        instance.textureRegistry = registrar.textures()

        let method = FlutterMethodChannel(name: "wxscan", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)

        let scan = FlutterEventChannel(name: "wxscan/scan", binaryMessenger: registrar.messenger())
        scan.setStreamHandler(instance)

        let size = FlutterEventChannel(name: "wxscan/preview_size", binaryMessenger: registrar.messenger())
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
            ensureScanner(
                detect: (args?["detectModel"] as? FlutterStandardTypedData)?.data,
                sr: (args?["srModel"] as? FlutterStandardTypedData)?.data
            )
            handleInitialize(result: result)
        case "setResolution":
            let want = (call.arguments as? [String: Any])?["shortSide"] as? Int ?? 720
            sessionQueue.async {
                self.shortSide = want
                if self.started {
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
        case "zoomRange":
            result(zoomRange())
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

    private func handleInitialize(result: @escaping FlutterResult) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            result(FlutterError(
                code: "NO_PERMISSION",
                message: "camera permission not granted",
                details: nil
            ))
            return
        }
        // Already running: hand Dart the current state, which is what a hot
        // reload or a re-entered page needs.
        if started {
            let (w, h) = currentPreviewSize()
            result(infoMap(width: w, height: h))
            return
        }

        sessionQueue.async {
            do {
                try self.setupSession()
                // The resolution is set on its own, because it opens a
                // configuration transaction of its own that must not nest
                // inside setupSession's.
                self.applyResolution()
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "INIT_ERROR", message: error.localizedDescription, details: nil))
                }
                return
            }

            DispatchQueue.main.async {
                let tex = WxScanTexture()
                self.texture = tex
                self.textureId = self.textureRegistry?.register(tex) ?? -1

                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                NotificationCenter.default.addObserver(
                    self, selector: #selector(self.onOrientationChanged),
                    name: UIDevice.orientationDidChangeNotification, object: nil
                )
                self.applyOrientation()

                self.sessionQueue.async {
                    self.session.startRunning()
                    self.started = true
                }

                let (w, h) = self.currentPreviewSize()
                self.sizeStream.push(width: w, height: h)
                result(self.infoMap(width: w, height: h))
            }
        }
    }

    private func infoMap(width: Int, height: Int) -> [String: Any] {
        [
            "textureId": textureId,
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
    private func applyOrientation() {
        guard let conn = videoOutput.connection(with: .video) else { return }
        let o = interfaceOrientation()
        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch o {
            case .portrait: angle = 90
            case .portraitUpsideDown: angle = 270
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            default: angle = 90
            }
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

    /// Creates the scanner once. A model that fails to load is not an error:
    /// the scanner falls back to the mode without models, which still decodes.
    private func ensureScanner(detect: Data?, sr: Data?) {
        guard scanner == nil else { return }
        scanner = WxScanBridge.create(detect: detect, sr: sr)
        modelsLoaded = scanner != nil && detect != nil
        if scanner == nil {
            scanner = WxScanBridge.create(detect: nil, sr: nil)
        }
    }

    private func releaseScanner() {
        // A frame may still be in flight on the scan queue holding this
        // pointer, so the release goes to the back of that queue.
        let s = scanner
        scanner = nil
        modelsLoaded = false
        scanQueue.async { WxScanBridge.destroy(s) }
    }

    private func teardown() {
        releaseScanner()
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()

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
            self.busy = false
            self.lastFrameLock.lock()
            self.lastY = nil; self.lastUV = nil
            self.lastFrameLock.unlock()
        }
    }

    private func err(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "wxscan", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
