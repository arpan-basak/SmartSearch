package com.example.smart_search_app

import kotlin.math.ceil

internal data class SemanticTextChunk(
    val content: String,
    val headings: List<String>,
)

/**
 * Produces model-sized, overlapping text windows without tying semantic
 * meaning to an arbitrary number of PDF pages.
 */
internal object SemanticTextChunker {
    private const val TARGET_TOKENS = 280
    private const val MAX_TOKENS = 350
    private const val OVERLAP_TOKENS = 50

    private data class Token(val start: Int, val end: Int)
    private data class Heading(val offset: Int, val text: String)

    fun chunk(value: String): List<SemanticTextChunk> {
        val text = value.replace("\r\n", "\n").replace('\r', '\n').trim()
        if (text.isEmpty()) return emptyList()
        val tokens = Regex("\\S+").findAll(text)
            .map { Token(it.range.first, it.range.last + 1) }.toList()
        if (tokens.isEmpty()) return emptyList()
        val headings = headings(text)
        if (tokens.size <= MAX_TOKENS) {
            return listOf(SemanticTextChunk(text, headings.map(Heading::text).distinct()))
        }

        val count = ceil(
            (tokens.size - OVERLAP_TOKENS).toDouble() /
                (TARGET_TOKENS - OVERLAP_TOKENS)
        ).toInt().coerceAtLeast(1)
        val chunkSize = ceil(
            (tokens.size + OVERLAP_TOKENS * (count - 1)).toDouble() / count
        ).toInt().coerceAtMost(MAX_TOKENS)
        val stride = (chunkSize - OVERLAP_TOKENS).coerceAtLeast(1)

        return buildList {
            var first = 0
            while (first < tokens.size) {
                val lastExclusive = minOf(tokens.size, first + chunkSize)
                val startOffset = tokens[first].start
                val endOffset = tokens[lastExclusive - 1].end
                val localHeadings = headings.filter {
                    it.offset in startOffset until endOffset
                }.map(Heading::text).toMutableList()
                headings.lastOrNull { it.offset <= startOffset }?.text?.let {
                    if (it !in localHeadings) localHeadings.add(0, it)
                }
                add(SemanticTextChunk(
                    text.substring(startOffset, endOffset).trim(),
                    localHeadings.distinct().take(6),
                ))
                if (lastExclusive == tokens.size) break
                first += stride
            }
        }
    }

    private fun headings(text: String): List<Heading> {
        val result = mutableListOf<Heading>()
        var offset = 0
        text.split('\n').forEach { raw ->
            val line = raw.trim()
            val wordCount = Regex("[\\p{L}\\p{N}]+").findAll(line).count()
            val markdown = Regex("^#{1,6}\\s+").containsMatchIn(line)
            val numbered = Regex("^(?:\\d+(?:\\.\\d+)*[.)]?|[IVXLC]+[.)])\\s+")
                .containsMatchIn(line)
            val upper = line.length >= 4 && line.any(Char::isLetter) &&
                line.filter(Char::isLetter).all(Char::isUpperCase)
            val titleCase = wordCount in 1..12 && line.split(Regex("\\s+"))
                .filter { it.any(Char::isLetter) }
                .count { it.firstOrNull()?.isUpperCase() == true } >=
                (wordCount * 2 + 2) / 3
            val terminalBodyPunctuation = line.endsWith('.') || line.endsWith('?') ||
                line.endsWith('!') || line.endsWith(';')
            if (line.length in 3..120 && wordCount in 1..14 &&
                (markdown || numbered || upper || (titleCase && !terminalBodyPunctuation))) {
                result += Heading(offset + raw.indexOf(line).coerceAtLeast(0),
                    line.removePrefix("#").trim().removeSuffix(":"))
            }
            offset += raw.length + 1
        }
        return result
    }
}
