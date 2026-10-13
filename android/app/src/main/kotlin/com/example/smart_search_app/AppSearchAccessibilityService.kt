package com.example.smart_search_app

import android.accessibilityservice.AccessibilityService
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Performs only a user-requested search in the specified foreground app.
 * It intentionally has no actions for checkout, payment, sign-in, messaging,
 * deletion, or any other sensitive activity.
 */
class AppSearchAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())

    private data class PendingSearch(
        val packageName: String,
        val query: String,
        var stage: Int = 0,
        val expiresAt: Long = System.currentTimeMillis() + SEARCH_TIMEOUT_MS,
    )

    private var pendingSearch: PendingSearch? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        activeService = this
    }

    override fun onDestroy() {
        if (activeService === this) activeService = null
        super.onDestroy()
    }

    override fun onInterrupt() {
        pendingSearch = null
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pending = pendingSearch ?: return
        if (System.currentTimeMillis() > pending.expiresAt) {
            pendingSearch = null
            return
        }
        if (event?.packageName?.toString() != pending.packageName) return
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ continueSearch() }, EVENT_SETTLE_DELAY_MS)
    }

    private fun beginSearch(packageName: String, query: String) {
        pendingSearch = PendingSearch(packageName, query)
    }

    private fun continueSearch() {
        val pending = pendingSearch ?: return
        val root = rootInActiveWindow ?: return
        try {
            when (pending.stage) {
                0 -> {
                    val input = findEditable(root)
                    if (input != null) {
                        enterQuery(input, pending.query)
                        pending.stage = 2
                    } else if (findAndClickSearch(root)) {
                        pending.stage = 1
                    }
                }
                1 -> {
                    findEditable(root)?.let {
                        enterQuery(it, pending.query)
                        pending.stage = 2
                    }
                }
                2 -> {
                    // Search buttons vary by app. Clicking a clearly-labelled search
                    // control is the final permitted step; no other controls are used.
                    if (findAndClickSearch(root)) pendingSearch = null
                }
            }
        } finally {
            root.recycle()
        }
    }

    private fun enterQuery(node: AccessibilityNodeInfo, query: String) {
        node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        node.performAction(
            AccessibilityNodeInfo.ACTION_SET_TEXT,
            Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, query)
            },
        )
    }

    private fun findEditable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isEditable && node.isEnabled) return node
        for (index in 0 until node.childCount) {
            val child = node.getChild(index) ?: continue
            val result = findEditable(child)
            if (result != null) return result
            child.recycle()
        }
        return null
    }

    private fun findAndClickSearch(node: AccessibilityNodeInfo): Boolean {
        val label = listOfNotNull(node.text, node.contentDescription)
            .joinToString(" ")
            .lowercase()
        if (!node.isEditable && node.isEnabled && node.isClickable && SEARCH_LABELS.any(label::contains)) {
            return node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }
        for (index in 0 until node.childCount) {
            val child = node.getChild(index) ?: continue
            val clicked = findAndClickSearch(child)
            child.recycle()
            if (clicked) return true
        }
        return false
    }

    companion object {
        private const val SEARCH_TIMEOUT_MS = 12_000L
        private const val EVENT_SETTLE_DELAY_MS = 350L
        private val SEARCH_LABELS = setOf("search", "find")

        @Volatile
        private var activeService: AppSearchAccessibilityService? = null

        fun requestSearch(packageName: String, query: String): Boolean {
            val service = activeService ?: return false
            service.beginSearch(packageName, query)
            return true
        }
    }
}
