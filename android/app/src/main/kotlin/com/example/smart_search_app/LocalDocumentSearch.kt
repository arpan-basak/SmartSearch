package com.example.smart_search_app

import android.content.Context

/** Full-text lookup over the transactional document/chunk SQLite index. */
internal object LocalDocumentSearch {
    /** Kept for callers that previously rebuilt a disposable JSON-derived DB. */
    fun prepare(context: Context) {
        DocumentIndexDatabase.ensureFreshStorage(context)
    }

    fun search(context: Context, query: String): List<Map<String, String>> =
        DocumentIndexDatabase.fullTextSearch(context, query)
}
