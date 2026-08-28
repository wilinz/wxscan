package com.wilinz.wxscanlive.core

/**
 * JNI entry point into the scanner, for callers that must not route frames
 * through Dart.
 *
 * The camera plugin uses this: frames go from CameraX straight into Rust. Dart
 * code that only needs to decode an image should use the FFI bindings of the
 * `wxscan` package instead.
 *
 * A handle is a number the library looks up in a table of its own, not an
 * address, so the same handle means the same thing on both paths and a stale
 * one is refused rather than followed. A scanner can therefore be shared: Dart
 * passes the handle of one it holds, this side [retain]s it, and whichever
 * lets go last is the one that frees it.
 *
 * Every handle taken — from [create] or [retain] — must be given back with
 * [release].
 */
object NativeScanner {
    init {
        // The Rust library has a DT_NEEDED entry for the TFLite C library, so the
        // loader normally brings it in; loading it first covers the cases where
        // it does not.
        try { System.loadLibrary("LiteRt") } catch (_: Throwable) {}
        // Not a leftover: the Rust crate behind the `wxscan` package keeps the
        // name `wxscan_core`, because it depends on the upstream `wxscan`
        // crate and cargo will not resolve a package against a dependency
        // sharing its own name. This is the library that crate produces.
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

    /**
     * Takes a reference to a scanner this side did not create, so that it stays
     * alive for as long as this side needs it.
     *
     * @return the same handle, or 0 if it names no scanner — which is what a
     *   handle left over from a previous Dart isolate looks like after a hot
     *   restart.
     */
    fun retain(handle: Long): Long = nativeRetain(handle)

    /** Gives a handle back. A handle of 0 is ignored. */
    fun release(handle: Long) = nativeRelease(handle)

    /**
     * Whether the scanner has its detector network loaded.
     *
     * Worth asking rather than inferring for a scanner this side was lent: it
     * was built elsewhere, from weights this side never saw.
     */
    fun hasDetector(handle: Long): Boolean = nativeHasDetector(handle)

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
    private external fun nativeRetain(handle: Long): Long
    private external fun nativeRelease(handle: Long)
    private external fun nativeHasDetector(handle: Long): Boolean
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
