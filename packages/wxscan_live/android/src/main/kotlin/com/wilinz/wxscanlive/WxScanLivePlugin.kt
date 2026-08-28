package com.wilinz.wxscanlive

import android.Manifest
import android.app.Activity
import com.wilinz.wxscanlive.core.NativeScanner
import android.content.ComponentCallbacks
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.util.Size
import android.content.res.Configuration
import android.view.OrientationEventListener
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import java.io.ByteArrayOutputStream
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.core.Camera
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors

/**
 * The preview goes through CameraX's Preview use case into a Flutter
 * SurfaceTexture, which stays on the GPU and costs no CPU per frame; scanning
 * goes through ImageAnalysis, whose Y plane reaches Rust over JNI without
 * passing through Dart.
 *
 * Orientation has two traps in it:
 * 1. Flutter's Texture applies the SurfaceTexture transform matrix, which
 *    already carries the sensor rotation. So Dart must *not* wrap the texture
 *    in a RotatedBox; it only has to size the box to the upright dimensions
 *    (see previewSizeStream).
 * 2. The preview's targetRotation is *pinned to ROTATION_0 and never changed*.
 *    CameraX uses it to bring the texture content upright with respect to the
 *    device's *natural* orientation, which is what keeps the size constant (a
 *    sensor mounted at 90 degrees turns 1280x720 into 720x1280), whatever
 *    orientation the phone happened to be in at launch. Wherever the screen
 *    then turns, a single RotatedBox on the Dart side makes up the difference
 *    from the current display rotation, which is the premise the official
 *    SurfaceTextureRotatedPreview sample builds on. Taking the orientation at
 *    bind time as a baseline and rotating by the delta was tried first; that
 *    extra baseline varies with the launch posture and is hard to verify, so
 *    it was abandoned.
 *
 *    ImageAnalysis's targetRotation does have to follow the screen, or the
 *    scan coordinates stop matching the preview. Reading the screen
 *    orientation is not a matter of reading it when an event arrives: during a
 *    rotation the configuration and the display disagree for a while. Sensor
 *    events and configuration callbacks are only triggers, and the settled
 *    value is read after a 120 ms debounce (see startOrientationListener);
 *    without that the reading can catch an intermediate state, or stick at the
 *    wrong orientation altogether.
 *
 * The scanner itself is the Dart code asset built by the wxscan package,
 * reached through [NativeScanner]. This plugin only handles frames, preview
 * and orientation; a frame goes from CameraX straight into Rust.
 */
class WxScanLivePlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, ActivityAware, LifecycleOwner {

    companion object {
        private const val TAG = "wxscan_live"

        /** Default capture resolution, in sensor orientation, so landscape.
         *  720p is enough for everyday codes; dense ones need more pixels to
         *  come out, and Dart picks the step (see WxResolution). */
        private const val ANALYSIS_WIDTH = 1280
        private const val ANALYSIS_HEIGHT = 720

        /** Short-side pixels to a target size, in landscape. 0 means the
         *  highest step, asked for here as 4K; CameraX falls back on its own
         *  if that is not available. */
        private fun targetSize(shortSide: Int): Size = when (shortSide) {
            720 -> Size(1280, 720)
            1080 -> Size(1920, 1080)
            0 -> Size(3840, 2160)
            else -> Size(shortSide * 16 / 9, shortSide)
        }

        /** Debounce after an orientation event: how long the rotation has to
         *  stay quiet before the actual configuration is read. */
        private const val ROTATION_CHECK_DELAY_MS = 120L

        /** How many times a change is re-checked, to cover the window where
         *  the configuration and the display update out of step. */
        private const val SETTLE_CHECKS = 3

    }

    /** Handle to the native scanner held by [NativeScanner]; 0 means none. */
    @Volatile private var scannerHandle: Long = 0L

    /** Whether the CNN models loaded. Scanning works without them, with a
     *  lower detection rate on weak codes. */
    @Volatile private var modelsLoaded = false

    private lateinit var appContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var sizeChannel: EventChannel
    private lateinit var textureRegistry: TextureRegistry

    private var activity: Activity? = null
    private val main = Handler(Looper.getMainLooper())

    /** Camera thread: takes the pixels and closes the image, nothing more.
     *  Scanning here would stall the camera's buffer queue. */
    private val camExec = Executors.newSingleThreadExecutor()
    /** Scan thread: runs Rust serially, dropping frames while busy. */
    private val worker = Executors.newSingleThreadExecutor()

    private val lifecycleRegistry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    private var scanSink: EventChannel.EventSink? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null

    /**
     * Set between the start of a bind and the camera provider answering, both
     * on the main thread.
     *
     * A second initialisation in that window would build a second
     * SurfaceTexture over the top of the first, leaving it registered with
     * nothing drawing into it — and a page that is entered and left repeatedly
     * does exactly that.
     */
    private var starting = false

    /**
     * Which camera session is open, or 0 when none is.
     *
     * The camera goes to whoever asked for it last, so "close the camera" is
     * not a thing a caller can be trusted to mean about the camera *it* opened
     * — by the time it says so, the camera may be someone else's. The number
     * is minted on every open, handed to Dart, and sent back with the close;
     * one that does not match is a caller closing a session that has already
     * ended, and closes nothing.
     */
    private var sessionId = 0L
    private var lastSessionId = 0L

    /** The shortSide the current binding was built with, to notice a takeover
     *  that asks for a different resolution. */
    private var boundShortSide = 0
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var previewSurface: Surface? = null
    private var preview: Preview? = null
    private var analysis: ImageAnalysis? = null

    // Size of the buffer the camera writes into the SurfaceTexture, in sensor
    // orientation.
    /// The most recent frame as NV21, for freezing the picture when several
    /// codes are in view. Stored in the original orientation and brought
    /// upright only when grabbed.
    @Volatile private var lastNv21: ByteArray? = null
    @Volatile private var lastNv21W = 0
    @Volatile private var lastNv21H = 0
    @Volatile private var lastNv21Rot = 0

    @Volatile private var bufW = ANALYSIS_WIDTH
    @Volatile private var bufH = ANALYSIS_HEIGHT

    /** Short-side pixels of the capture resolution; 0 means the device's
     *  highest. Changing it takes effect only after rebinding the use cases. */
    @Volatile private var shortSide = ANALYSIS_HEIGHT
    // Size of the picture in the texture, already upright with respect to the
    // device's natural orientation, and therefore constant.
    @Volatile private var previewW = ANALYSIS_HEIGHT
    @Volatile private var previewH = ANALYSIS_WIDTH

    /**
     * How far the camera turned the buffer to bring the texture upright, the
     * sensor's own mounting angle. Kept because focus points arrive in the
     * upright picture's coordinates and metering wants the buffer's.
     */
    @Volatile private var previewRotation = 90
    private var orientationListener: OrientationEventListener? = null
    private var configCallback: ComponentCallbacks? = null
    private var lastTargetRotation = Surface.ROTATION_0
    /** Settle re-checks left; touched on the main thread only. */
    private var settleChecksLeft = 0

    /**
     * How far the screen is turned from the device's natural orientation.
     *
     * The picture in the SurfaceTexture is upright with respect to that
     * natural orientation, so in landscape Dart has to make up the difference
     * itself. This value is how much; at 0 Dart does nothing.
     */
    @Volatile private var displayRotationDegrees = 0

    @Volatile private var busy = false
    @Volatile private var scanning = true
    @Volatile private var nativeReady = false

    // Crude timing: one line every 30 frames, to see the scan latency on a
    // real device.
    private var statFrames = 0
    private var statTotalMs = 0L
    private var statMaxMs = 0L

    // ---------- FlutterPlugin ----------
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        textureRegistry = binding.textureRegistry
        methodChannel = MethodChannel(binding.binaryMessenger, "wxscan_live")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "wxscan_live/scan")
        eventChannel.setStreamHandler(this)
        sizeChannel = EventChannel(binding.binaryMessenger, "wxscan_live/preview_size")
        sizeChannel.setStreamHandler(sizeHandler)
        nativeReady = try { NativeScanner.ping() == "wxscan" } catch (_: Throwable) { false }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        sizeChannel.setStreamHandler(null)
        teardown()
        // The end of this registry, and the only place that says so. Guarded
        // for the same reason as the move in [teardown]: a plugin whose
        // camera was never opened has a registry still at INITIALIZED, and
        // androidx refuses that move rather than ignoring it.
        if (lifecycleRegistry.currentState.isAtLeast(Lifecycle.State.CREATED)) {
            lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        }
        // After teardown, never before: it posts the scanner's release onto
        // `worker`, and shutdown() lets what is already queued run. These are
        // two non-daemon threads per plugin instance, so a host that attaches
        // and detaches engines — add-to-app, or a FlutterEngineGroup — would
        // otherwise accumulate a pair per cycle for the life of the process.
        worker.shutdown()
        camExec.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() {}
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }

    // ---------- EventChannel ----------
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { scanSink = events }
    override fun onCancel(arguments: Any?) { scanSink = null }

    // ---------- MethodChannel ----------
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                call.argument<Int>("shortSide")?.let { shortSide = it }
                handleInitialize(
                    result,
                    call.argument<ByteArray>("detectModel"),
                    call.argument<ByteArray>("srModel"),
                    // A scanner Dart already holds, to be borrowed rather than
                    // built. Absent means build one here.
                    // Widths are the native side's business: a value too
                    // large for a handle there names no scanner, and is
                    // refused rather than truncated into one that exists.
                    call.argument<Number>("scannerHandle")?.toLong() ?: 0L,
                )
            }
            // Changing resolution means rebinding the use cases, which is all
            // CameraX offers. The texture is the same one, so Dart rebuilds
            // nothing.
            "setResolution" -> {
                val want = call.argument<Int>("shortSide") ?: ANALYSIS_HEIGHT
                if (want == shortSide || cameraProvider == null) {
                    result.success(null)
                } else {
                    shortSide = want
                    main.post {
                        try {
                            rebindUseCases()
                            result.success(null)
                        } catch (e: Throwable) {
                            result.error("RESOLUTION_ERROR", e.message, null)
                        }
                    }
                }
            }
            "setScanning" -> {
                scanning = call.argument<Boolean>("value") ?: true
                result.success(null)
            }
            "setTorch" -> {
                val on = call.argument<Boolean>("value") ?: false
                try {
                    camera?.cameraControl?.enableTorch(on)
                    result.success(null)
                } catch (e: Throwable) {
                    result.error("TORCH_ERROR", e.message, null)
                }
            }
            "hasTorch" -> result.success(camera?.cameraInfo?.hasFlashUnit() ?: false)
            // Grab the most recent frame as an upright JPEG, for freezing the
            // picture when several codes are in view.
            "grabFrame" -> {
                try {
                    result.success(grabJpeg())
                } catch (e: Throwable) {
                    android.util.Log.e(TAG, "grabFrame err: ${e.message}")
                    result.success(null)
                }
            }
            // Zoom. The ratio is absolute and is clamped to what the device
            // supports; what comes back is the ratio that took effect.
            "setZoom" -> {
                val want = (call.argument<Double>("ratio") ?: 1.0).toFloat()
                try {
                    val info = camera?.cameraInfo
                    val state = info?.zoomState?.value
                    if (state == null) {
                        result.success(1.0)
                    } else {
                        val clamped = want.coerceIn(state.minZoomRatio, state.maxZoomRatio)
                        camera?.cameraControl?.setZoomRatio(clamped)
                        result.success(clamped.toDouble())
                    }
                } catch (e: Throwable) {
                    result.error("ZOOM_ERROR", e.message, null)
                }
            }
            // Tap to focus. The point is a fraction of the upright picture,
            // which is the buffer turned by the sensor's mounting angle, so it
            // is turned back before metering.
            "focusAt" -> {
                val x = call.argument<Double>("x") ?: -1.0
                val y = call.argument<Double>("y") ?: -1.0
                result.success(focusAt(x, y))
            }
            "zoomRange" -> {
                val state = camera?.cameraInfo?.zoomState?.value
                result.success(
                    mapOf(
                        "min" to (state?.minZoomRatio ?: 1f).toDouble(),
                        "max" to (state?.maxZoomRatio ?: 1f).toDouble(),
                        "current" to (state?.zoomRatio ?: 1f).toDouble(),
                    )
                )
            }
            // Self test: takes exactly the path a camera frame takes, a Y
            // plane with row padding through rotation and JNI, to confirm on a
            // real device that that stretch works.
            "selfTestNative" -> {
                val gray = call.argument<ByteArray>("gray")
                val w = call.argument<Int>("width") ?: 0
                val h = call.argument<Int>("height") ?: 0
                val rot = call.argument<Int>("rotation") ?: 0
                if (gray == null || w <= 0 || h <= 0) {
                    result.error("BAD_ARGS", "missing grayscale data", null); return
                }
                worker.execute {
                    // 16 bytes of row padding on purpose, to imitate
                    // CameraX's rowStride.
                    val stride = w + 16
                    val padded = ByteArray(stride * h)
                    for (y in 0 until h) {
                        System.arraycopy(gray, y * w, padded, y * stride, w)
                    }
                    val t0 = android.os.SystemClock.elapsedRealtime()
                    val json = try {
                        NativeScanner.scanFrame(scannerHandle, padded, w, h, stride, rot, false)
                    } catch (e: Throwable) { "ERR ${e.message}" }
                    val dt = android.os.SystemClock.elapsedRealtime() - t0
                    android.util.Log.i(TAG, "selfTestNative rot=$rot ${dt}ms -> $json")
                    main.post { result.success(json) }
                }
            }
            // Closing the camera is the one call that can be sent by someone
            // who no longer owns it: a controller that lost the camera to a
            // later one and is now being disposed. The session it names says
            // which, and a stale one closes nothing. Zero — a caller with no
            // session of its own — still closes, since that is the only way
            // anything can be closed by a caller that never opened it.
            "dispose" -> {
                val session = call.argument<Number>("sessionId")?.toLong() ?: 0L
                if (session == 0L || session == sessionId) teardown()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Settles which scanner frames are decoded with.
     *
     * Dart may hand over the handle of one it already holds — the same scanner
     * an application uses for pictures from its photo library. Then there is
     * one set of CNN weights in memory rather than two, and one set of
     * thresholds that cannot drift apart. This side takes its own reference to
     * it either way, so the scanner outlives whichever side lets go first.
     *
     * Otherwise one is built here. A model that fails to load is not an error:
     * it falls back to plain image processing, which still scans, with a lower
     * detection rate on distant or small codes.
     */
    private fun ensureScanner(detect: ByteArray?, sr: ByteArray?, borrowed: Long) {
        // Whatever was held is given back first, unconditionally. Only the
        // caller that is about to own the camera reaches this — the ones that
        // failed, and the one that found a bind in flight, have returned
        // already — so a scanner left over from before belongs to nobody that
        // is still reading frames. Keeping it would decode the new owner's
        // frames with weights it never asked for, and report the previous
        // scanner's `modelsLoaded` as if it were this one's.
        //
        // Left over from what: the caller that just lost the camera to this
        // one, a hot restart, which leaves this plugin running while
        // everything it was lent goes away, or an initialize that settled a
        // scanner and then failed to bind a camera.
        //
        // The camera may be running while this swaps the handle out, on a
        // takeover. The analyser reads the field per frame and skips a zero,
        // and the release is queued behind whatever frame is in flight on the
        // worker, so the swap is seen between frames and never under one.
        //
        // Releasing before retaining is safe even when it is the same scanner
        // twice over — but not for the reason the queueing suggests: the
        // queued release and the retain here run on different threads with no
        // ordering between them. What makes it safe is that a non-zero
        // `borrowed` can only come from a WxScanner Dart still holds, since
        // reading its handle after disposal throws. That reference outlives
        // both operations, so the count cannot reach zero in either order.
        releaseScanner()

        if (borrowed != 0L) {
            // A retain that comes back 0 means the handle names no scanner:
            // stale, from an isolate that is gone. Falling through and building
            // one here is better than a camera that decodes nothing.
            scannerHandle = try { NativeScanner.retain(borrowed) } catch (_: Throwable) { 0L }
            if (scannerHandle != 0L) {
                // Built elsewhere, from weights this side never saw, so the
                // answer is asked for rather than inferred.
                modelsLoaded = try {
                    NativeScanner.hasDetector(scannerHandle)
                } catch (_: Throwable) { false }
                return
            }
        }

        val empty = ByteArray(0)
        scannerHandle = try {
            NativeScanner.create(detect ?: empty, sr ?: empty)
        } catch (_: Throwable) { 0L }
        modelsLoaded = scannerHandle != 0L && detect != null
        if (scannerHandle == 0L) {
            scannerHandle = try { NativeScanner.create(empty, empty) } catch (_: Throwable) { 0L }
        }
    }

    /** Gives back the reference this side holds, if it holds one. */
    private fun releaseScanner() {
        if (scannerHandle == 0L) return
        val h = scannerHandle
        scannerHandle = 0L
        modelsLoaded = false
        // The frame being scanned still names this handle, so the release goes
        // to the back of the worker queue. It is only this side's reference in
        // any case: if Dart still holds the scanner, nothing is freed here.
        worker.execute { try { NativeScanner.release(h) } catch (_: Throwable) {} }
    }

    /**
     * Opens the camera, settling the scanner only once this call is known to
     * be the one that will configure it.
     *
     * The scanner used to be settled first, before the permission check and
     * before [bindCamera]'s "already bound" check. That meant a call that went
     * on to fail, or one that only wanted the state of a camera already
     * running, had already swapped the scanner out from under whoever was
     * using it — and the running camera then decoded every frame against a
     * handle of zero, silently, for as long as it stayed open.
     */
    private fun handleInitialize(
        result: MethodChannel.Result,
        detect: ByteArray?,
        sr: ByteArray?,
        borrowed: Long,
    ) {
        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            activity?.requestPermissions(arrayOf(Manifest.permission.CAMERA), 0x0C0DE)
            result.error(
                "NO_PERMISSION",
                "camera permission not granted; a request was sent, try again once it is",
                null,
            )
            return
        }
        main.post { bindCamera(result, detect, sr, borrowed) }
    }

    private fun infoMap(textureId: Long): Map<String, Any> = mapOf(
        "textureId" to textureId,
        "sessionId" to sessionId,
        "previewWidth" to previewW,
        "previewHeight" to previewH,
        "displayRotation" to displayRotationDegrees,
        "nativeReady" to nativeReady,
        "modelsLoaded" to modelsLoaded
    )

    private fun bindCamera(
        result: MethodChannel.Result,
        detect: ByteArray?,
        sr: ByteArray?,
        borrowed: Long,
    ) {
        // Already bound, so this is a takeover: the camera goes to the caller
        // that asked last, and the one that had it is told by its own Dart
        // side. Rebinding is not how it is done — that would build a second
        // SurfaceTexture and drop the first without releasing it — so what
        // changes hands is the session, the scanner, and the resolution, over
        // the camera already running.
        //
        // A hot restart arrives here looking exactly like a second caller:
        // this plugin outlived the isolate and still holds the camera, while
        // everything Dart lent it is gone. Handing over is the answer to both,
        // which is why there is no attempt to tell them apart.
        val bound = textureEntry
        if (bound != null && cameraProvider != null) {
            sessionId = ++lastSessionId
            // The frames in flight are decoded with whatever this settles on;
            // the caller that had the camera is not reading them any more.
            ensureScanner(detect, sr, borrowed)
            if (shortSide != boundShortSide) {
                try { rebindUseCases() } catch (_: Throwable) {}
            }
            result.success(infoMap(bound.id()))
            return
        }
        if (starting) {
            result.error("BUSY", "the camera is already starting", null)
            return
        }
        ensureScanner(detect, sr, borrowed)
        starting = true
        try {
            lifecycleRegistry.currentState = Lifecycle.State.RESUMED
            // A bind that failed part way leaves its entry behind, and the
            // registry holds it until someone says otherwise.
            textureEntry?.let { try { it.release() } catch (_: Throwable) {} }
            val entry = textureRegistry.createSurfaceTexture()
            textureEntry = entry
            val st: SurfaceTexture = entry.surfaceTexture()

            val future = ProcessCameraProvider.getInstance(appContext)
            future.addListener({
                // The page can be left again while the provider is being
                // fetched. Teardown clears this and has released the entry, so
                // there is nothing left to bind to.
                if (!starting) {
                    result.error("CANCELLED", "the camera was disposed while starting", null)
                    return@addListener
                }
                try {
                    val provider = future.get()
                    cameraProvider = provider
                    bindUseCases(st)
                    sessionId = ++lastSessionId
                    starting = false
                    main.post { result.success(infoMap(entry.id())) }
                } catch (e: Throwable) {
                    starting = false
                    result.error("INIT_ERROR", e.message, null)
                }
            }, ContextCompat.getMainExecutor(appContext))
        } catch (e: Throwable) {
            starting = false
            result.error("INIT_ERROR", e.message, null)
        }
    }

    /**
     * Builds and binds the preview and analysis use cases.
     *
     * It is a method of its own because changing resolution has to go through
     * it: a CameraX use case fixes its resolution at build time, so a new step
     * means rebuilding and rebinding. The SurfaceTexture is reused, so the
     * textureId Dart holds does not change and the interface is not rebuilt.
     */
    private fun bindUseCases(st: SurfaceTexture) {
        val provider = cameraProvider ?: return
        provider.unbindAll()
        boundShortSide = shortSide

        val selector = CameraSelector.DEFAULT_BACK_CAMERA

        // The resolution is stated explicitly: setTargetResolution is
        // deprecated as of CameraX 1.3, and on some devices it picks something
        // like a 1952x1952 square, three times the work for nothing.
        val resolution = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .setResolutionStrategy(
                ResolutionStrategy(
                    targetSize(shortSide),
                    // Prefer the smaller one: doubling the resolution
                    // multiplies the per-frame cost and does not help
                    // scanning.
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER
                )
            )
            .build()

        lastTargetRotation = uiRotation()
        displayRotationDegrees = rotationDegrees(lastTargetRotation)

        // Preview: CameraX Preview into a Flutter SurfaceTexture, with
        // targetRotation pinned to ROTATION_0, so the texture is always
        // upright with respect to the natural orientation.
        val previewUseCase = Preview.Builder()
            .setResolutionSelector(resolution)
            .setTargetRotation(Surface.ROTATION_0)
            .build()
        previewUseCase.setSurfaceProvider { request: SurfaceRequest ->
            val res = request.resolution
            android.util.Log.i(
                TAG,
                "surface request ${res.width}x${res.height} (current buf=${bufW}x$bufH)"
            )
            // The buffer keeps the size the camera gives, in sensor
            // orientation.
            st.setDefaultBufferSize(res.width, res.height)
            bufW = res.width
            bufH = res.height
            val surface = Surface(st)
            previewSurface = surface
            recomputePreviewSize()
            request.provideSurface(surface, ContextCompat.getMainExecutor(appContext)) {
                surface.release()
            }
        }
        preview = previewUseCase

        // Analysis: the Y plane of YUV_420_888 is already the grayscale
        // image, so it goes straight to Rust.
        val analysisUseCase = ImageAnalysis.Builder()
            .setResolutionSelector(resolution)
            .setTargetRotation(lastTargetRotation)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
        analysisUseCase.setAnalyzer(camExec, ::analyze)
        analysis = analysisUseCase

        camera = provider.bindToLifecycle(
            this, selector, previewUseCase, analysisUseCase
        )
        startOrientationListener()

        previewUseCase.resolutionInfo?.resolution?.let {
            bufW = it.width; bufH = it.height
        }
        recomputePreviewSize()
    }

    /** Rebinds the use cases at the current shortSide, to change resolution.
     *  Must be called on the main thread. */
    private fun rebindUseCases() {
        val st = textureEntry?.surfaceTexture() ?: return
        bindUseCases(st)
    }

    private fun displayRotation(): Int =
        try {
            @Suppress("DEPRECATION")
            activity?.windowManager?.defaultDisplay?.rotation ?: Surface.ROTATION_0
        } catch (_: Throwable) { Surface.ROTATION_0 }

    /**
     * Orientation listening, following the official camera_android_camerax
     * DeviceOrientationManager: the triggers, the sensor and configuration
     * changes, only schedule a delayed re-read, and the angle itself comes
     * from reading the actual configuration after the debounce.
     *
     * During a physical rotation Configuration.orientation and
     * display.getRotation() disagree for a while, so reading the instant an
     * event arrives catches an intermediate state -- the 90 to 0 to 90 jitter
     * visible in the log. Worse, the last sensor event can arrive before the
     * configuration settles, and with nothing left to trigger another read the
     * orientation would stay wrong for good, the preview cropped by cover into
     * a strip that looks like half a blank screen. The configuration change
     * callback is the authoritative signal that things have settled, which is
     * what the official implementation relies on
     * (ACTION_CONFIGURATION_CHANGED) to avoid exactly that.
     */
    private fun startOrientationListener() {
        val ctx = activity ?: appContext
        orientationListener?.disable()
        orientationListener = object : OrientationEventListener(ctx) {
            override fun onOrientationChanged(orientation: Int) {
                scheduleRotationCheck()
            }
        }.apply { if (canDetectOrientation()) enable() }

        // The system calls back here once the configuration has really
        // settled, so a re-read happens even with no further sensor event.
        configCallback?.let { activity?.unregisterComponentCallbacks(it) }
        configCallback = object : ComponentCallbacks {
            override fun onConfigurationChanged(newConfig: Configuration) {
                scheduleRotationCheck()
            }
            override fun onLowMemory() {}
        }
        @Suppress("DEPRECATION")
        activity?.registerComponentCallbacks(configCallback!!)

        scheduleRotationCheck()
    }

    /**
     * Waits for the rotation events to stay quiet for 120 ms before reading.
     * They come thick during a rotation, one every 45 degrees, and each resets
     * the timer, so what is finally read is normally the settled value.
     */
    private fun scheduleRotationCheck() {
        main.removeCallbacks(rotationCheck)
        main.postDelayed(rotationCheck, ROTATION_CHECK_DELAY_MS)
    }

    private val rotationCheck = object : Runnable {
        override fun run() {
            val rot = uiRotation()
            if (rot != lastTargetRotation) {
                lastTargetRotation = rot
                // Only the analysis use case follows, so the corner
                // coordinates share the preview's frame of reference. The
                // preview's targetRotation stays put and Dart makes up the
                // rotation.
                analysis?.targetRotation = rot
                displayRotationDegrees = rotationDegrees(rot)
                android.util.Log.i(TAG, "ui rotated -> ${displayRotationDegrees}deg")
                pushPreviewSize()
                // It just changed, so re-check a few more times: a single
                // read can still land on the intermediate state where the
                // configuration and the display disagree, and seeing a change
                // means it has not settled yet.
                settleChecksLeft = SETTLE_CHECKS
            } else {
                settleChecksLeft--
            }
            if (settleChecksLeft > 0) main.postDelayed(this, ROTATION_CHECK_DELAY_MS)
        }
    }

    /**
     * The current UI orientation, as a Surface.ROTATION_* constant.
     *
     * Configuration.orientation settles portrait against landscape and
     * display.getRotation() settles which way round, which together give the
     * orientation the interface is *actually* in, the one Dart's layout sees.
     */
    private fun uiRotation(): Int {
        val rotation = displayRotation()
        val ctx = activity ?: appContext
        return when (ctx.resources.configuration.orientation) {
            Configuration.ORIENTATION_PORTRAIT ->
                if (rotation == Surface.ROTATION_0 || rotation == Surface.ROTATION_90)
                    Surface.ROTATION_0 else Surface.ROTATION_180
            Configuration.ORIENTATION_LANDSCAPE ->
                if (rotation == Surface.ROTATION_0 || rotation == Surface.ROTATION_90)
                    Surface.ROTATION_90 else Surface.ROTATION_270
            else -> Surface.ROTATION_0
        }
    }

    private fun rotationDegrees(rot: Int): Int = when (rot) {
        Surface.ROTATION_90 -> 90
        Surface.ROTATION_180 -> 180
        Surface.ROTATION_270 -> 270
        else -> 0
    }

    /**
     * Works out the size of the picture in the texture.
     *
     * The point is that the SurfaceTexture transform matrix comes from the
     * camera and only brings the sensor orientation round to the device's
     * *natural* orientation, independently of targetRotation. So this size is
     * constant, and TransformationInfo's rotationDegrees cannot be used to
     * compute it: that one follows the screen, and in landscape it would swap
     * the dimensions.
     */
    private fun recomputePreviewSize() {
        // CameraX has already brought the texture content upright per the
        // targetRotation given at bind time, and how far it turned has to be
        // worked out here: preview.resolutionInfo.rotationDegrees is no use,
        // because on the SurfaceTexture path the transform is already applied
        // and that field reports what is *left* to turn, which is always 0.
        // targetRotation is pinned to ROTATION_0, so the angle turned is the
        // sensor's own mounting angle.
        val sensor = try {
            camera?.cameraInfo?.sensorRotationDegrees ?: 90
        } catch (_: Throwable) { 90 }
        val rot = ((sensor % 360) + 360) % 360
        val w = if (rot % 180 == 0) bufW else bufH
        val h = if (rot % 180 == 0) bufH else bufW
        if (w == previewW && h == previewH) return
        android.util.Log.i(
            TAG,
            "preview buf=${bufW}x$bufH sensor=$sensor rot=$rot -> ${w}x$h"
        )
        previewW = w
        previewH = h
        previewRotation = rot
        pushPreviewSize()
    }

    private fun pushPreviewSize() {
        sizeHandler.sink?.success(previewSizeMap())
    }

    /**
     * Focuses and meters on one point of the upright picture, given as
     * fractions of its width and height.
     *
     * [SurfaceOrientedMeteringPointFactory] works in the coordinates of the
     * buffer the camera writes, which is the picture in the texture turned
     * *back* by [previewRotation] — the angle the camera turned it by to bring
     * it upright. Rotating a point clockwise by 90 sends (x, y) to (1 - y, x),
     * so undoing it sends (x, y) to (y, 1 - x), and so on round.
     *
     * The action is left to cancel itself: CameraX returns to continuous
     * auto-focus a few seconds later, which is what a scanner wants when the
     * reader has moved on and is not tapping any more.
     */
    private fun focusAt(x: Double, y: Double): Boolean {
        if (x < 0.0 || x > 1.0 || y < 0.0 || y > 1.0) return false
        val cam = camera ?: return false
        val (bx, by) = when (previewRotation) {
            90 -> y to (1 - x)
            180 -> (1 - x) to (1 - y)
            270 -> (1 - y) to x
            else -> x to y
        }
        return try {
            val point = SurfaceOrientedMeteringPointFactory(1f, 1f)
                .createPoint(bx.toFloat(), by.toFloat())
            val action = FocusMeteringAction.Builder(
                point,
                FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE
            ).build()
            if (!cam.cameraInfo.isFocusMeteringSupported(action)) return false
            cam.cameraControl.startFocusAndMetering(action)
            true
        } catch (e: Throwable) {
            android.util.Log.w(TAG, "focusAt err: ${e.message}")
            false
        }
    }

    private fun previewSizeMap(): Map<String, Any> = mapOf(
        "width" to previewW,
        "height" to previewH,
        "displayRotation" to displayRotationDegrees
    )

    private val sizeHandler = object : EventChannel.StreamHandler {
        @Volatile var sink: EventChannel.EventSink? = null
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            sink = events
            // A new subscriber gets the current value first, so it cannot
            // miss the initial state.
            events?.success(previewSizeMap())
        }
        override fun onCancel(arguments: Any?) { sink = null }
    }

    /// ImageProxy (YUV_420_888) to NV21. Every plane has its own rowStride
    /// and pixelStride, so it is read row by row and pixel by pixel.
    private fun toNv21(image: ImageProxy): ByteArray {
        val w = image.width
        val h = image.height
        val out = ByteArray(w * h * 3 / 2)

        val yPlane = image.planes[0]
        val yBuf = yPlane.buffer.duplicate()
        val yRowStride = yPlane.rowStride
        var pos = 0
        for (row in 0 until h) {
            yBuf.position(row * yRowStride)
            yBuf.get(out, pos, w)
            pos += w
        }

        // NV21 interleaves chroma as VU.
        val uBuf = image.planes[1].buffer.duplicate()
        val vBuf = image.planes[2].buffer.duplicate()
        val uvRowStride = image.planes[1].rowStride
        val uvPixelStride = image.planes[1].pixelStride
        for (row in 0 until h / 2) {
            for (col in 0 until w / 2) {
                val idx = row * uvRowStride + col * uvPixelStride
                out[pos++] = vBuf.get(idx)
                out[pos++] = uBuf.get(idx)
            }
        }
        return out
    }

    /// Compresses the buffered frame to JPEG and brings it upright per the
    /// capture orientation. The upright size matches the analysis frame, so
    /// Dart can draw its markers in one set of coordinates.
    private fun grabJpeg(): ByteArray? {
        val nv21 = lastNv21 ?: return null
        val w = lastNv21W
        val h = lastNv21H
        if (w == 0 || h == 0) return null

        val bos = ByteArrayOutputStream()
        YuvImage(nv21, ImageFormat.NV21, w, h, null)
            .compressToJpeg(Rect(0, 0, w, h), 88, bos)
        val rot = ((lastNv21Rot % 360) + 360) % 360
        if (rot == 0) return bos.toByteArray()

        val raw = bos.toByteArray()
        val bmp = BitmapFactory.decodeByteArray(raw, 0, raw.size) ?: return raw
        val m = Matrix().apply { postRotate(rot.toFloat()) }
        val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
        val out = ByteArrayOutputStream()
        rotated.compress(Bitmap.CompressFormat.JPEG, 88, out)
        if (rotated !== bmp) bmp.recycle()
        rotated.recycle()
        return out.toByteArray()
    }

    // ---------- per frame ----------
    private fun analyze(image: ImageProxy) {
        val y: ByteArray
        val w: Int
        val h: Int
        val rowStride: Int
        val rot: Int
        try {
            val plane = image.planes[0]          // the Y plane is the grayscale image
            rowStride = plane.rowStride
            w = image.width
            h = image.height
            rot = image.imageInfo.rotationDegrees
            y = ByteArray(plane.buffer.remaining())
            plane.buffer.get(y)

            // Keep a colour copy while we are here: with several codes in
            // view the picture is frozen for the user to choose from, and
            // freezing this same frame is what makes the markers line up with
            // it for free.
            if (scanning) {
                lastNv21 = toNv21(image)
                lastNv21W = w
                lastNv21H = h
                lastNv21Rot = rot
            }
        } catch (e: Throwable) {
            android.util.Log.e(TAG, "grab err: ${e.message}")
            image.close()
            return
        }
        image.close()   // released at once, without waiting for the scan

        if (!scanning || !nativeReady || scannerHandle == 0L || busy) return
        busy = true
        // A frame that got past the guard just as the engine went away would
        // otherwise hand work to an executor that has been shut down, and the
        // rejection would surface as an uncaught exception on CameraX's
        // analyser thread. Unbinding does not wait for a frame already in
        // flight, so this window is real however the teardown is ordered.
        try {
            submitScan(y, w, h, rowStride, rot)
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            busy = false
        }
    }

    /** Decodes one frame off the camera thread. See [analyze]. */
    private fun submitScan(y: ByteArray, w: Int, h: Int, rowStride: Int, rot: Int) {
        worker.execute {
            try {
                val t0 = android.os.SystemClock.elapsedRealtime()
                // The back camera shows what the eye sees, so the coordinates
                // are not flipped.
                val json = NativeScanner.scanFrame(scannerHandle, y, w, h, rowStride, rot, false)
                val dt = android.os.SystemClock.elapsedRealtime() - t0

                statFrames++
                statTotalMs += dt
                if (dt > statMaxMs) statMaxMs = dt
                if (statFrames >= 30) {
                    val n = statFrames
                    android.util.Log.i(
                        TAG,
                        "scan ${statTotalMs / n}ms avg / ${statMaxMs}ms max (${w}x$h rot=$rot)"
                    )
                    statFrames = 0; statTotalMs = 0; statMaxMs = 0
                }

                main.post { scanSink?.success(json) }
            } catch (e: Throwable) {
                android.util.Log.e(TAG, "scan err: ${e.message}")
            } finally {
                busy = false
            }
        }
    }

    private fun teardown() {
        // Before anything is released, so a bind still in flight sees it and
        // does not attach the camera to a texture that is about to go.
        starting = false
        orientationListener?.disable()
        orientationListener = null
        @Suppress("DEPRECATION")
        configCallback?.let { activity?.unregisterComponentCallbacks(it) }
        configCallback = null
        main.removeCallbacks(rotationCheck)
        preview = null
        analysis = null
        try { cameraProvider?.unbindAll() } catch (_: Throwable) {}
        cameraProvider = null
        camera = null
        try { previewSurface?.release() } catch (_: Throwable) {}
        previewSurface = null
        try { textureEntry?.release() } catch (_: Throwable) {}
        textureEntry = null
        // Down to CREATED, not DESTROYED, and only from at least CREATED.
        //
        // Two things androidx will not do. It refuses INITIALIZED to
        // DESTROYED outright — "State must be at least CREATED to move to
        // DESTROYED" — which is the state this registry is in whenever the
        // camera was never opened, and detaching the engine tears down
        // regardless. And a registry that reaches DESTROYED cannot be brought
        // back up, so the next camera would have nothing to bind to.
        //
        // CREATED is below STARTED, which is what unbinds the use cases, and
        // it is a state the next bind can move up from. DESTROYED is said
        // once, in [onDetachedFromEngine], where the plugin really is going.
        if (lifecycleRegistry.currentState.isAtLeast(Lifecycle.State.CREATED)) {
            lifecycleRegistry.currentState = Lifecycle.State.CREATED
        }
        // Never reused: the ids only go up, so a close that arrives late
        // names a session that has ended rather than the next one.
        sessionId = 0L
        boundShortSide = 0
        releaseScanner()
    }
}
