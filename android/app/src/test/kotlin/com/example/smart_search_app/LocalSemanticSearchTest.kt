package com.example.smart_search_app

import android.app.Application
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.Base64

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class, manifest = Config.NONE)
class LocalSemanticSearchTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private fun vector(vararg values: Int): String = Base64.getEncoder()
        .encodeToString(ByteArray(values.size) { values[it].toByte() })

    @Before fun setUp() = DocumentIndexDatabase.clear(context)

    @After fun tearDown() = DocumentIndexDatabase.clear(context)

    private fun addFile(
        path: String,
        name: String,
        fileEmbedding: String,
        vararg chunks: Pair<String, String>,
    ) {
        val source = mapOf(
            "path" to path, "name" to name, "type" to "application/pdf",
            "modified" to "1", "size" to "1000", "folder" to "Documents/",
        )
        chunks.forEachIndexed { index, (content, embedding) ->
            DocumentIndexDatabase.commitFile(
                context,
                source,
                listOf(source + mapOf(
                    "content" to content, "chunkIndex" to index.toString(),
                    "embedding" to embedding, "chunkEmbedding" to embedding,
                    "summary" to name, "profileVersion" to "6",
                    "extractionVersion" to "7",
                )),
                fileEmbedding,
                "hash-$path",
                1L,
                index == 0,
                index == chunks.lastIndex,
            )
        }
    }

    @Test fun returnsTheBestChunkOncePerFile() {
        addFile(
            "gpu", "GPU.pdf", vector(90, 90),
            "intro" to vector(127, 0),
            "coalesced memory" to vector(0, 127),
        )
        addFile(
            "kitchen", "Kitchen.pdf", vector(-90, -90),
            "cupboards" to vector(0, -127),
        )

        val results = LocalSemanticSearch.search(context, vector(0, 127))
        assertEquals("gpu", results.first()["path"])
        assertEquals("coalesced memory", results.first()["content"])
        assertEquals(1, results.count { it["path"] == "gpu" })
        assertTrue(results.first().getValue("semanticScore").toDouble() > .99)
    }
}
