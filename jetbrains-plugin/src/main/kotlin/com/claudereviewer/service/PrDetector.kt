package com.claudereviewer.service

import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.util.ExecUtil
import com.intellij.openapi.project.Project

data class PrInfo(val url: String, val platform: String)

object PrDetector {

    fun detect(project: Project): PrInfo? {
        val basePath = project.basePath ?: return null

        // Try GitHub
        tryGitHub(basePath)?.let { return it }

        // Try GitLab
        tryGitLab(basePath)?.let { return it }

        return null
    }

    private fun tryGitHub(basePath: String): PrInfo? {
        return try {
            val cmd = GeneralCommandLine("gh", "pr", "view", "--json", "url", "-q", ".url")
                .withWorkDirectory(basePath)
            val output = ExecUtil.execAndGetOutput(cmd)
            val url = output.stdout.trim()
            if (url.startsWith("http")) PrInfo(url, "github") else null
        } catch (_: Exception) {
            null
        }
    }

    private fun tryGitLab(basePath: String): PrInfo? {
        return try {
            val cmd = GeneralCommandLine("glab", "mr", "view", "--output", "json")
                .withWorkDirectory(basePath)
            val output = ExecUtil.execAndGetOutput(cmd)
            val json = output.stdout.trim()
            // Find all web_url values and pick the MR URL (not author profile)
            val urlPattern = Regex(""""web_url"\s*:\s*"(https?://[^"]+)"""")
            val mrUrl = urlPattern.findAll(json)
                .map { it.groupValues[1] }
                .firstOrNull { it.contains("/merge_requests/") }
            mrUrl?.let { PrInfo(it, "gitlab") }
        } catch (_: Exception) {
            null
        }
    }
}
