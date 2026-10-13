package com.example.smart_search_app

import android.content.Context
import android.util.Base64
import java.util.PriorityQueue
import kotlin.math.sqrt

/** Exact top-K over the private quantized vectors. Every valid vector is still
 * scored; the cached binary corpus and JNI SIMD path only reduce representation
 * and arithmetic overhead. */
internal object LocalSemanticSearch {
    private const val EMBEDDING_DIMENSIONS = 384
    private data class SemanticKey(val path: String, val chunkIndex: Int)
    private data class Scored(val score: Double, val key: SemanticKey)

    private data class Corpus(
        val revision: String,
        val dimensions: Int,
        val rows: List<SemanticKey>,
        val chunkVectors: ByteArray,
        val fileVectors: ByteArray,
        val chunkMagnitudes: DoubleArray,
        val fileMagnitudes: DoubleArray,
    )

    private val corpusLock = Any()
    @Volatile private var cachedCorpus: Corpus? = null

    fun activateRequest(requestId: Long) {
        ExactVectorSearch.activateRequest(requestId)
    }

    fun clearCache() = synchronized(corpusLock) {
        cachedCorpus = null
    }

    fun prepare(context: Context, shouldContinue: () -> Boolean = { true }): Int =
        corpus(context, EMBEDDING_DIMENSIONS, shouldContinue)?.rows?.size ?: 0

    fun search(
        context: Context,
        queryEmbedding: String,
        limit: Int = 50,
        requestId: Long = 0L,
        shouldContinue: () -> Boolean = { true },
    ): List<Map<String, String>> {
        if (queryEmbedding.isBlank() || limit <= 0 || !shouldContinue()) return emptyList()
        val query = decode(queryEmbedding) ?: return emptyList()
        activateRequest(requestId)
        val corpus = corpus(context, query.size, shouldContinue) ?: return emptyList()
        if (!shouldContinue()) return emptyList()

        val nativeScores = runCatching {
            ExactVectorSearch.score(
                requestId,
                query,
                corpus.chunkVectors,
                corpus.fileVectors,
                corpus.chunkMagnitudes,
                corpus.fileMagnitudes,
                corpus.dimensions,
            )
        }.getOrNull()
        val queryMagnitude = magnitude(query)
        val bestByPath = linkedMapOf<String, Scored>()
        for (index in corpus.rows.indices) {
            if (!shouldContinue()) return emptyList()
            val score = nativeScores?.getOrNull(index) ?: maxOf(
                cosine(
                    query,
                    queryMagnitude,
                    corpus.chunkVectors,
                    index * corpus.dimensions,
                    corpus.chunkMagnitudes[index],
                ),
                cosine(
                    query,
                    queryMagnitude,
                    corpus.fileVectors,
                    index * corpus.dimensions,
                    corpus.fileMagnitudes[index],
                ),
            )
            val key = corpus.rows[index]
            if (key.path.isBlank()) continue
            val current = bestByPath[key.path]
            if (current == null || score > current.score) {
                bestByPath[key.path] = Scored(score, key)
            }
        }

        val top = PriorityQueue<Scored>(compareBy(Scored::score))
        bestByPath.values.forEach { scored ->
            if (top.size < limit) top += scored
            else if (scored.score > (top.peek()?.score ?: Double.NEGATIVE_INFINITY)) {
                top.poll()
                top += scored
            }
        }
        val ranked = top.toList().sortedByDescending(Scored::score)
        val resultRows = DocumentIndexDatabase.semanticResultRows(
            context,
            ranked.map { Pair(it.key.path, it.key.chunkIndex) },
        )
        return ranked.mapIndexedNotNull { rank, scored ->
                val row = resultRows[Pair(scored.key.path, scored.key.chunkIndex)]
                    ?: return@mapIndexedNotNull null
                buildMap {
                    putAll(row.filterKeys { it != "content" })
                    put("path", scored.key.path)
                    put("content", row["content"].orEmpty().take(2400))
                    put("semanticRank", (rank + 1).toString())
                    put("semanticScore", scored.score.toString())
                    put("retrievalReasons", "Semantic passage match")
                }
            }
    }

    private fun corpus(
        context: Context,
        dimensions: Int,
        shouldContinue: () -> Boolean,
    ): Corpus? {
        val revision = DocumentIndexDatabase.revisionStamp(context)
        cachedCorpus?.takeIf { it.revision == revision && it.dimensions == dimensions }
            ?.let { return it }
        if (!shouldContinue()) return null
        return synchronized(corpusLock) {
            cachedCorpus?.takeIf { it.revision == revision && it.dimensions == dimensions }
                ?: buildCorpus(context, revision, dimensions, shouldContinue)?.also {
                    cachedCorpus = it
                }
        }
    }

    private fun buildCorpus(
        context: Context,
        revision: String,
        dimensions: Int,
        shouldContinue: () -> Boolean,
    ): Corpus? {
        val source = DocumentIndexDatabase.semanticRows(context)
        if (!shouldContinue()) return null
        val valid = source.mapNotNull { row ->
            val chunk = row.chunkEmbedding?.takeIf { it.size == dimensions }
            val file = row.fileEmbedding?.takeIf { it.size == dimensions }
            if (chunk == null && file == null) null else Triple(
                SemanticKey(row.path, row.chunkIndex), chunk, file,
            )
        }
        val chunks = ByteArray(valid.size * dimensions)
        val files = ByteArray(valid.size * dimensions)
        val chunkMagnitudes = DoubleArray(valid.size)
        val fileMagnitudes = DoubleArray(valid.size)
        valid.forEachIndexed { index, (_, chunk, file) ->
            if (!shouldContinue()) return null
            val offset = index * dimensions
            chunk?.copyInto(chunks, offset)
            file?.copyInto(files, offset)
            if (chunk != null) chunkMagnitudes[index] = magnitude(chunk)
            if (file != null) fileMagnitudes[index] = magnitude(file)
        }
        return Corpus(
            revision = revision,
            dimensions = dimensions,
            rows = valid.map { it.first },
            chunkVectors = chunks,
            fileVectors = files,
            chunkMagnitudes = chunkMagnitudes,
            fileMagnitudes = fileMagnitudes,
        )
    }

    private fun decode(value: String): ByteArray? = try {
        Base64.decode(value, Base64.NO_WRAP).takeIf { it.isNotEmpty() }
    } catch (_: IllegalArgumentException) {
        null
    }

    private fun magnitude(values: ByteArray): Double {
        var squared = 0.0
        values.forEach { value ->
            val component = value.toInt().toDouble()
            squared += component * component
        }
        return if (squared == 0.0) 0.0 else sqrt(squared)
    }

    private fun cosine(
        query: ByteArray,
        queryMagnitude: Double,
        corpus: ByteArray,
        offset: Int,
        vectorMagnitude: Double,
    ): Double {
        if (queryMagnitude == 0.0 || vectorMagnitude == 0.0) return -1.0
        var dot = 0.0
        for (dimension in query.indices) {
            dot += query[dimension].toInt() * corpus[offset + dimension].toInt()
        }
        return dot / (queryMagnitude * vectorMagnitude)
    }
}
