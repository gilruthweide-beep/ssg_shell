package com.ssg.ssg_shell

import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale

/**
 * §11.6 Console ring buffer.
 *
 * Diagnostics must display and export the most recent N console entries; logcat alone is insufficient
 * on production devices without logcat access. Evict the oldest entry at capacity.
 */
internal class ConsoleLogBuffer(@Volatile var capacity: Int = 300) {

    private val records = ArrayDeque<ConsoleRecord>()

    fun add(record: ConsoleRecord) = synchronized(records) {
        records.addLast(record)
        while (records.size > capacity.coerceAtLeast(1)) records.removeFirst()
    }

    fun snapshot(): List<ConsoleRecord> = synchronized(records) { records.toList() }

    fun clear() = synchronized(records) { records.clear() }

    /** §11.6 Plain-text format for exports. */
    fun dump(): String = snapshot().joinToString("\n") { r ->
        val where = r.source?.let { s -> "$s:${r.line ?: 0}" } ?: "-"
        "${FORMAT.format(Date(r.atMs))} [${r.level.name.lowercase(Locale.ROOT)}] $where ${r.message}"
    }

    private companion object {
        val FORMAT = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.ROOT)
    }
}
