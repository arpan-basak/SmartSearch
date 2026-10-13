package com.example.smart_search_app

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.util.Base64
import java.nio.LongBuffer
import java.text.Normalizer
import kotlin.math.sqrt

/** Lazy, offline all-MiniLM-L6-v2 inference. It is first opened by a settled
 * query or the background indexer, never during application startup. */
internal object MiniLmTextEmbedder {
    private const val MODEL_ASSET = "all_minilm_l6_v2_qint8.onnx"
    private const val VOCAB_ASSET = "minilm_vocab.txt"
    private const val MAX_SEQUENCE_LENGTH = 256
    private val lock = Any()
    private var runtime: Runtime? = null
    private val recent = object : LinkedHashMap<String, String>(64, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?): Boolean =
            size > 64
    }

    private data class Runtime(
        val environment: OrtEnvironment,
        val session: OrtSession,
        val tokenizer: WordPieceTokenizer,
    )

    fun embed(context: Context, value: String): String = synchronized(lock) {
        if (value.isBlank()) return@synchronized ""
        // WordPiece lowercases and treats runs of whitespace identically, so a
        // canonical cache key reuses mathematically identical query embeddings.
        val cacheKey = value.trim().lowercase().replace(Regex("\\s+"), " ")
        recent[cacheKey]?.let { return@synchronized it }
        try {
            val active = runtime ?: createRuntime(context.applicationContext).also {
                runtime = it
            }
            val encoded = active.tokenizer.encode(cacheKey, MAX_SEQUENCE_LENGTH)
            val shape = longArrayOf(1, MAX_SEQUENCE_LENGTH.toLong())
            OnnxTensor.createTensor(active.environment, LongBuffer.wrap(encoded.inputIds), shape).use { ids ->
                OnnxTensor.createTensor(active.environment, LongBuffer.wrap(encoded.attentionMask), shape).use { mask ->
                    OnnxTensor.createTensor(active.environment, LongBuffer.wrap(encoded.tokenTypes), shape).use { types ->
                        val inputs = mutableMapOf<String, OnnxTensor>()
                        if ("input_ids" in active.session.inputNames) inputs["input_ids"] = ids
                        if ("attention_mask" in active.session.inputNames) inputs["attention_mask"] = mask
                        if ("token_type_ids" in active.session.inputNames) inputs["token_type_ids"] = types
                        active.session.run(inputs).use { result ->
                            @Suppress("UNCHECKED_CAST")
                            val hidden = result[0].value as Array<Array<FloatArray>>
                            val pooled = FloatArray(hidden[0][0].size)
                            var included = 0
                            for (tokenIndex in hidden[0].indices) {
                                if (encoded.attentionMask[tokenIndex] == 0L) continue
                                included++
                                for (dimension in pooled.indices) {
                                    pooled[dimension] += hidden[0][tokenIndex][dimension]
                                }
                            }
                            if (included == 0) return@synchronized ""
                            var magnitude = 0.0
                            for (dimension in pooled.indices) {
                                pooled[dimension] /= included.toFloat()
                                magnitude += pooled[dimension] * pooled[dimension]
                            }
                            val norm = sqrt(magnitude).toFloat()
                            if (norm == 0f) return@synchronized ""
                            val quantized = ByteArray(pooled.size) { dimension ->
                                ((pooled[dimension] / norm) * 127f)
                                    .toInt().coerceIn(-127, 127).toByte()
                            }
                            Base64.encodeToString(quantized, Base64.NO_WRAP).also {
                                recent[cacheKey] = it
                            }
                        }
                    }
                }
            }
        } catch (_: Exception) {
            ""
        }
    }

    private fun createRuntime(context: Context): Runtime {
        val environment = OrtEnvironment.getEnvironment()
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(2)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        }
        val model = context.assets.open(MODEL_ASSET).use { it.readBytes() }
        val session = environment.createSession(model, options)
        val vocab = context.assets.open(VOCAB_ASSET).bufferedReader().useLines {
            lines -> lines.mapIndexed { index, token -> token to index }.toMap()
        }
        return Runtime(environment, session, WordPieceTokenizer(vocab))
    }

    private data class Encoded(
        val inputIds: LongArray,
        val attentionMask: LongArray,
        val tokenTypes: LongArray,
    )

    private class WordPieceTokenizer(private val vocabulary: Map<String, Int>) {
        private val unknown = vocabulary["[UNK]"] ?: 100
        private val cls = vocabulary["[CLS]"] ?: 101
        private val sep = vocabulary["[SEP]"] ?: 102

        fun encode(value: String, length: Int): Encoded {
            val pieces = mutableListOf(cls)
            basicTokens(value).forEach { token ->
                if (pieces.size >= length - 1) return@forEach
                pieces += wordPieces(token).take(length - 1 - pieces.size)
            }
            pieces += sep
            val ids = LongArray(length)
            val mask = LongArray(length)
            pieces.take(length).forEachIndexed { index, id ->
                ids[index] = id.toLong()
                mask[index] = 1L
            }
            return Encoded(ids, mask, LongArray(length))
        }

        private fun basicTokens(value: String): List<String> {
            val normalized = Normalizer.normalize(value.lowercase(), Normalizer.Form.NFD)
                .filter { Character.getType(it) != Character.NON_SPACING_MARK.toInt() }
            val output = mutableListOf<String>()
            val current = StringBuilder()
            fun flush() {
                if (current.isNotEmpty()) output += current.toString()
                current.setLength(0)
            }
            normalized.forEach { char ->
                when {
                    char.isLetterOrDigit() -> current.append(char)
                    char.isWhitespace() -> flush()
                    else -> {
                        flush()
                        output += char.toString()
                    }
                }
            }
            flush()
            return output
        }

        private fun wordPieces(token: String): List<Int> {
            vocabulary[token]?.let { return listOf(it) }
            if (token.length > 100) return listOf(unknown)
            val result = mutableListOf<Int>()
            var start = 0
            while (start < token.length) {
                var end = token.length
                var found: Int? = null
                while (start < end) {
                    val candidate = (if (start == 0) "" else "##") +
                        token.substring(start, end)
                    found = vocabulary[candidate]
                    if (found != null) break
                    end--
                }
                if (found == null) return listOf(unknown)
                result += found
                start = end
            }
            return result
        }
    }
}
