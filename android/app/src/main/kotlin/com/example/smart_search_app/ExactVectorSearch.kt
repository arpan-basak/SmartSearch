package com.example.smart_search_app

/**
 * Exact cosine scoring backed by a small JNI implementation. The native path
 * evaluates every vector and only changes how the arithmetic is executed; it
 * is not an approximate nearest-neighbour index.
 */
internal object ExactVectorSearch {
    private val nativeAvailable = runCatching {
        System.loadLibrary("exact_vector_search")
        true
    }.getOrDefault(false)

    fun activateRequest(requestId: Long) {
        if (nativeAvailable) nativeActivateRequest(requestId)
    }

    fun score(
        requestId: Long,
        query: ByteArray,
        chunkVectors: ByteArray,
        fileVectors: ByteArray,
        chunkMagnitudes: DoubleArray,
        fileMagnitudes: DoubleArray,
        dimensions: Int,
    ): DoubleArray? {
        if (!nativeAvailable) return null
        return nativeScoreExact(
            requestId,
            query,
            chunkVectors,
            fileVectors,
            chunkMagnitudes,
            fileMagnitudes,
            dimensions,
        )
    }

    private external fun nativeActivateRequest(requestId: Long)

    private external fun nativeScoreExact(
        requestId: Long,
        query: ByteArray,
        chunkVectors: ByteArray,
        fileVectors: ByteArray,
        chunkMagnitudes: DoubleArray,
        fileMagnitudes: DoubleArray,
        dimensions: Int,
    ): DoubleArray
}
