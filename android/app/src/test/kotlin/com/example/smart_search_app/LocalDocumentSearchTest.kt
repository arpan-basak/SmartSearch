package com.example.smart_search_app

import android.app.Application
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

/** AOSP-backed SQLite checks; these do not substitute for phone latency tests. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], application = Application::class, manifest = Config.NONE)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class LocalDocumentSearchTest {
    private val context get() = RuntimeEnvironment.getApplication()

    @Before fun setUp() = DocumentIndexDatabase.clear(context)

    @After fun tearDown() = DocumentIndexDatabase.clear(context)

    private fun writeRows(vararg rows: Pair<String, String>) {
        DocumentIndexDatabase.clear(context)
        rows.forEachIndexed { i, (name, content) ->
            val source = mapOf(
                "name" to name, "type" to "application/pdf",
                "path" to "file-$i", "modified" to "$i", "size" to "1000",
                "folder" to "Documents/",
            )
            val chunk = source + mapOf(
                "content" to content, "chunkIndex" to "0", "bytes" to content.length.toString(),
                "summary" to name, "headings" to "", "embedding" to "",
                "profileVersion" to "6", "extractionVersion" to "7",
            )
            DocumentIndexDatabase.commitFile(
                context, source, listOf(chunk), "", "hash-$i", 1L, true, true,
            )
        }
    }

    @Test fun fullTextFindsDeepContentAndReturnsBoundedExcerpt() {
        writeRows("Unknown.pdf" to ("ordinary filler words ".repeat(5000) + " syllabus course outline"),
            "Unrelated.pdf" to "kitchen shopping list")
        LocalDocumentSearch.prepare(context)
        val hits = LocalDocumentSearch.search(context, "syllabus")
        assertEquals(1, hits.size)
        assertEquals("file-0", hits.single()["path"])
        assertTrue(hits.single().getValue("content").contains("syllabus"))
        assertTrue(hits.single().getValue("content").length < 2000)
    }

    @Test fun changedAndDeletedDocumentsDoNotRemainInDerivedIndex() {
        writeRows("Syllabus.pdf" to "syllabus course outline")
        assertEquals(1, LocalDocumentSearch.search(context, "syllabus").size)
        writeRows("Kitchen.pdf" to "cupboard measurements")
        LocalDocumentSearch.prepare(context)
        assertTrue(LocalDocumentSearch.search(context, "syllabus").isEmpty())
        assertEquals(1, LocalDocumentSearch.search(context, "kitchen").size)
    }

    @Test fun allHitsRemainAvailableAndQueriesAreBoundParameters() {
        writeRows(*Array(80) { "Syllabus $it.pdf" to "syllabus course outline" })
        assertEquals(80, LocalDocumentSearch.search(context, "syllabus").size)
        assertTrue(LocalDocumentSearch.search(context, "' ; DROP TABLE searchable; --").isEmpty())
        assertEquals(80, LocalDocumentSearch.search(context, "syllabus").size)
    }

    @Test fun fts4PrefixesMatchPartialWords() {
        writeRows("Unknown.pdf" to "assignment coursework")
        assertEquals(1, LocalDocumentSearch.search(context, "assign").size)
        assertEquals(1, LocalDocumentSearch.search(context, "assignmen").size)
    }
}
