package com.claudereviewer.toolwindow

import com.intellij.execution.filters.TextConsoleBuilderFactory
import com.intellij.execution.ui.ConsoleView
import com.intellij.openapi.project.Project
import com.intellij.openapi.wm.ToolWindow
import com.intellij.openapi.wm.ToolWindowFactory
import com.intellij.ui.content.ContentFactory

class ReviewToolWindowFactory : ToolWindowFactory {

    override fun createToolWindowContent(project: Project, toolWindow: ToolWindow) {
        val console = TextConsoleBuilderFactory.getInstance().createBuilder(project).console
        val content = ContentFactory.getInstance().createContent(console.component, "Review Output", false)
        toolWindow.contentManager.addContent(content)
        // Store console reference for later use
        project.putUserData(CONSOLE_KEY, console)
    }

    companion object {
        val CONSOLE_KEY = com.intellij.openapi.util.Key.create<ConsoleView>("ClaudeReviewer.Console")
    }
}
