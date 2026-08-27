package com.wilinz.wxscan.core

/**
 * JNI entry point into the scanner, for callers that must not route frames
 * through Dart.
 *
 * The camera plugin uses this: frames go from CameraX straight into Rust. Dart
 * code that only needs to decode an image should use the FFI bindings of the
 * `wxscan_core` package instead; the two paths share this library but own
 * separate scanner instances.
 *
 * A handle returned by [create] must be released with [destroy].
 */
object NativeScanner {
    init {
        // The Rust library has a DT_NEEDED entry for the TFLite C library, so the
        // loader normally brings it in; loading it first covers the cases where
        // it does not.
        try { System.loadLibrary("LiteRt") } catch (_: Throwable) {}
        System.loadLibrary("wxscan_core")
    }

    /**
     * Creates a scanner from TFLite model bytes. Empty arrays select the mode
     * without models, which still decodes but detects small or distant symbols
     * less reliably.
     *
     * @return an opaque handle, or 0 if a model failed to load.
     */
    fun create(detect: ByteArray, sr: ByteArray): Long = nativeCreate(detect, sr)

    /** Releases a handle from [create]. A handle of 0 is ignored. */
    fun destroy(handle: Long) = nativeDestroy(handle)

    /**
     * Scans one camera frame.
     *
     * @param yPlane the Y plane, [rowStride] bytes per row.
     * @param rotation clockwise degrees needed to bring the frame upright.
     * @param mirror mirrors the returned x coordinates; the frame itself is
     *   never mirrored, because the detector is trained on unmirrored input.
     * @return a JSON document with the frame size, the results and the detector
     *   candidates. Invalid input yields an empty document, never an exception.
     */
    fun scanFrame(
        handle: Long,
        yPlane: ByteArray,
        width: Int,
        height: Int,
        rowStride: Int,
        rotation: Int,
        mirror: Boolean,
    ): String = nativeScanFrame(handle, yPlane, width, height, rowStride, rotation, mirror)

    /** Returns a fixed string once the library is loaded, for diagnostics. */
    fun ping(): String = nativePing()

    private external fun nativeCreate(detect: ByteArray, sr: ByteArray): Long
    private external fun nativeDestroy(handle: Long)
    private external fun nativeScanFrame(
        handle: Long,
        yPlane: ByteArray,
        width: Int,
        height: Int,
        rowStride: Int,
        rotation: Int,
        mirror: Boolean,
    ): String
    private external fun nativePing(): String
}
