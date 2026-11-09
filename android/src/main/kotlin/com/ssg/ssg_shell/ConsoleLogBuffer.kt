package com.ssg.ssg_shell

import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale

/**
 * §11.6 console 环形缓冲。
 *
 * 诊断入口要能「查看并导出最近 N 条 console」，所以日志不能只进 logcat ——
 * 线上设备拿不到 logcat。容量满了丢最旧的。
 */
internal class ConsoleLogBuffer(@Volatile var capacity: Int = 300) {

    private val records = ArrayDeque<ConsoleRecord>()

    fun add(record: ConsoleRecord) = synchronized(records) {
        records.addLast(record)
        while (records.size > capacity.coerceAtLeast(1)) records.removeFirst()
    }

    fun snapshot(): List<ConsoleRecord> = synchronized(records) { records.toList() }

    fun clear() = synchronized(records) { records.clear() }

    /** §11.6 导出用的纯文本。 */
    fun dump(): String = snapshot().joinToString("\n") { r ->
        val where = r.source?.let { s -> "$s:${r.line ?: 0}" } ?: "-"
        "${FORMAT.format(Date(r.atMs))} [${r.level.name.lowercase(Locale.ROOT)}] $where ${r.message}"
    }

    private companion object {
        val FORMAT = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.ROOT)
    }
}
