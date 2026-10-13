package com.example.smart_search_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SemanticTextChunkerTest {
    @Test fun longTextUsesBoundedOverlappingWindows() {
        val text = "CUDA MEMORY OPTIMIZATION\n" +
            (1..800).joinToString(" ") { "token$it" }
        val chunks = SemanticTextChunker.chunk(text)

        assertTrue(chunks.size >= 3)
        chunks.forEach { chunk ->
            assertTrue(Regex("\\S+").findAll(chunk.content).count() <= 350)
        }
        val firstWords = chunks[0].content.split(Regex("\\s+"))
        val secondWords = chunks[1].content.split(Regex("\\s+"))
        assertEquals(firstWords.takeLast(50), secondWords.take(50))
        assertTrue(chunks.first().headings.contains("CUDA MEMORY OPTIMIZATION"))
        assertTrue(chunks[1].headings.contains("CUDA MEMORY OPTIMIZATION"))
    }

    @Test fun shortTextRemainsOneChunk() {
        val chunks = SemanticTextChunker.chunk("Introduction\nA short useful paragraph.")
        assertEquals(1, chunks.size)
        assertEquals("Introduction\nA short useful paragraph.", chunks.single().content)
    }
}
