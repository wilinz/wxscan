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
     * Creates a scanner from weight files on disk.
     *
     * The library reads them, so a megabyte of weights never crosses JNI. A
     * null path means that network is absent, as an empty array is to [create].
     *
     * @throws ModelFileException when a path cannot be read or is not weights.
     *   A missing file is the caller's mistake and worth saying so: weights
     *   that quietly fail to load leave the scanner on plain image processing,
     *   and the only symptom is a detection rate nobody is measuring.
     */
    fun createFromPaths(detect: String?, sr: String?): Long {
        val id = nativeCreatePath(detect, sr)
        if (id > 0) return id
        // The native side has no out-parameter to spare, so it answers a
        // failure with minus the status that explains it. See the Rust doc on
        // nativeCreatePath; the encoding ends here.
        throw when (-id) {
            STATUS_BAD_ARGUMENT -> ModelFileException("a model path is not valid text")
            STATUS_UNREADABLE ->
                ModelFileException("a model file could not be read: detect=$detect sr=$sr")
            STATUS_WEIGHTS_REFUSED ->
                ModelFileException("a model file was read but is not weights this build can load")
            else -> ModelFileException("the scanner could not be created from those paths")
        }
    }

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
    private external fun nativeCreatePath(detect: String?, sr: String?): Long
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

    // WxScanStatus, as the C ABI numbers them. Only nativeCreatePath returns
    // these, and only negated.
    private const val STATUS_BAD_ARGUMENT = 1L
    private const val STATUS_UNREADABLE = 2L
    private const val STATUS_WEIGHTS_REFUSED = 4L
}

/** A weight file that could not be read, or that is not weights. */
class ModelFileException(message: String) : Exception(message)
