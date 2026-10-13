package com.example.smart_search_app

import android.content.Context

/** Bounded evidence from the prepared full-text and knowledge-graph indexes.
 * Does not scan files, rebuild the graph, or change foreground search request IDs. */
internal object ChatContextSearch {
    fun search(context: Context, query: String): List<Map<String, String>> {
        if (query.isBlank()) return emptyList()
        val rows = DocumentIndexer.search(context, query.take(1600), includeSemantic = false)
        fun rank(row: Map<String, String>): Double = listOf("ftsRank", "graphRank")
            .sumOf { key ->
                val position = row[key]?.toIntOrNull() ?: 0
                if (position > 0) 1.0 / (60 + position) else 0.0
            }
        return rows.asSequence()
            .filter { !it["path"].isNullOrBlank() && !it["content"].isNullOrBlank() }
            .sortedByDescending(::rank)
            .distinctBy { it["path"] }
            .take(5)
            .map { row -> mapOf(
                "path" to row["path"].orEmpty(),
                "name" to row["name"].orEmpty().take(160),
                "content" to row["content"].orEmpty().take(2400),
                "retrievalReasons" to row["retrievalReasons"].orEmpty().take(240),
            ) }.toList()
    }
}
