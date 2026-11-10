package com.ssg.ssg_shell

import org.junit.Assert.assertEquals
import org.junit.Test

class ShellConfigTest {
    private fun config(entryUrl: String, legacyChannel: String = "ChannelCode_google") =
        ShellConfig(
            entryUrl = entryUrl,
            channelCode = legacyChannel,
            shellVersion = "1.0.2",
            bSideEnabled = true,
        )

    @Test
    fun `no channel parameter is added even with a legacy configured channel`() {
        for (url in listOf("https://im.example.com/", "https://im.example.com/?a=1#home")) {
            assertEquals(url, config(url).resolvedUrl())
        }
    }

    @Test
    fun `channel parameter casing and empty values are preserved`() {
        for (name in listOf("channelcode", "channelCode", "ChannelCode", "CHANNELCODE")) {
            for (value in listOf("fromWeb", "")) {
                val url = "https://im.example.com/?$name=$value"
                assertEquals(url, config(url).resolvedUrl())
            }
        }
    }

    @Test
    fun `query encoding repeated parameters and fragment are preserved`() {
        val url = "https://im.example.com/?channelcode=ch%2f001&tag=a+%20b" +
            "&tag=%2526&channelcode=second#/chat?channelcode=fragment"
        assertEquals(url, config(url).resolvedUrl())
        assertEquals(url, config(url, legacyChannel = "").resolvedUrl())
    }

    @Test
    fun `fragment channel parameter is not copied into query`() {
        val url = "https://im.example.com/?redirect=%2fchat#/home?channelcode=fragment"
        assertEquals(url, config(url).resolvedUrl())
    }

    @Test
    fun `empty entry remains empty`() {
        assertEquals("", config("").resolvedUrl())
    }
}
