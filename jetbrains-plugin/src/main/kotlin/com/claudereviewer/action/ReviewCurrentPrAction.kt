package com.claudereviewer.action

import com.claudereviewer.service.PrDetector
import com.claudereviewer.service.ReviewRunner
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.ui.Messages

class ReviewCurrentPrAction : AnAction() {

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return

        val prInfo = PrDetector.detect(project)
        if (prInfo == null) {
            Messages.showErrorDialog(
                project,
                "No PR/MR found for the current branch.\n\n" +
                    "Push your branch and create a PR/MR first.\n" +
                    "Ensure gh or glab CLI is authenticated.",
                "Claude Code Reviewer"
            )
            return
        }

        Messages.showInfoMessage(
            project,
            "Found: ${prInfo.url}\nStarting review...",
            "Claude Code Reviewer"
        )

        ReviewRunner.execute(project, prInfo.url)
    }
}
