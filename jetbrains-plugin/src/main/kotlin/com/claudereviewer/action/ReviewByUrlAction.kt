package com.claudereviewer.action

import com.claudereviewer.service.ReviewRunner
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.ui.Messages

class ReviewByUrlAction : AnAction() {

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return

        val url = Messages.showInputDialog(
            project,
            "Enter the PR/MR URL to review:",
            "Claude Code Reviewer",
            null
        )

        if (url.isNullOrBlank()) return

        val pattern = Regex("https?://.+(pull/\\d+|merge_requests/\\d+)")
        if (!pattern.containsMatchIn(url)) {
            Messages.showErrorDialog(
                project,
                "Invalid URL. Enter a GitHub PR (*/pull/N) or GitLab MR (*/merge_requests/N) URL.",
                "Claude Code Reviewer"
            )
            return
        }

        ReviewRunner.execute(project, url)
    }
}
