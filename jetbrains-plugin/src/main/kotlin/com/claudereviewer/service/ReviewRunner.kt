package com.claudereviewer.service

import com.claudereviewer.toolwindow.ReviewToolWindowFactory
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.OSProcessHandler
import com.intellij.execution.process.ProcessAdapter
import com.intellij.execution.process.ProcessEvent
import com.intellij.execution.ui.ConsoleView
import com.intellij.execution.ui.ConsoleViewContentType
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.Messages
import com.intellij.openapi.wm.ToolWindowManager
import java.io.File

object ReviewRunner {

    private val INSTALL_DIR = File(System.getProperty("user.home"), "claude-code-reviewer")
    private const val REPO_URL = "https://github.com/shubhesh07/claude-code-reviewer.git"

    fun execute(project: Project, prUrl: String) {
        val reviewShPath = findReviewSh()
        if (reviewShPath == null) {
            promptAndInstall(project, prUrl)
            return
        }

        startReview(project, reviewShPath, prUrl)
    }

    private fun promptAndInstall(project: Project, prUrl: String) {
        val choice = Messages.showYesNoDialog(
            project,
            "Claude Code Reviewer CLI is not installed.\n\n" +
                "Install it automatically to ~/claude-code-reviewer?",
            "Claude Code Reviewer — Setup",
            "Install & Review",
            "Cancel",
            Messages.getQuestionIcon()
        )
        if (choice != Messages.YES) return

        // Show tool window and run install
        ApplicationManager.getApplication().invokeLater {
            val toolWindow = ToolWindowManager.getInstance(project).getToolWindow("Claude Reviewer")
            toolWindow?.show()
        }

        ApplicationManager.getApplication().executeOnPooledThread {
            runInstall(project, prUrl)
        }
    }

    private fun runInstall(project: Project, prUrl: String) {
        val console = project.getUserData(ReviewToolWindowFactory.CONSOLE_KEY) ?: return
        val currentPath = buildPath()

        printToConsole(console, "=" .repeat(60) + "\n", ConsoleViewContentType.NORMAL_OUTPUT)
        printToConsole(console, "Setting up Claude Code Reviewer...\n", ConsoleViewContentType.NORMAL_OUTPUT)
        printToConsole(console, "=" .repeat(60) + "\n\n", ConsoleViewContentType.NORMAL_OUTPUT)

        // Step 1: Clone
        if (INSTALL_DIR.exists() && File(INSTALL_DIR, "review.sh").exists()) {
            printToConsole(console, "Repository already exists, pulling latest...\n", ConsoleViewContentType.NORMAL_OUTPUT)
            val pullResult = runCommand(listOf("git", "-C", INSTALL_DIR.absolutePath, "pull"), currentPath)
            if (!pullResult.success) {
                printToConsole(console, "Warning: git pull failed: ${pullResult.output}\n", ConsoleViewContentType.ERROR_OUTPUT)
            }
        } else {
            printToConsole(console, "Cloning $REPO_URL...\n", ConsoleViewContentType.NORMAL_OUTPUT)
            val cloneResult = runCommand(listOf("git", "clone", REPO_URL, INSTALL_DIR.absolutePath), currentPath)
            if (!cloneResult.success) {
                printToConsole(console, "Clone failed: ${cloneResult.output}\n", ConsoleViewContentType.ERROR_OUTPUT)
                return
            }
            printToConsole(console, "Cloned successfully.\n\n", ConsoleViewContentType.NORMAL_OUTPUT)
        }

        // Step 2: Run setup.sh --auto
        val setupSh = File(INSTALL_DIR, "setup.sh")
        if (setupSh.exists()) {
            printToConsole(console, "Running setup.sh --auto...\n", ConsoleViewContentType.NORMAL_OUTPUT)
            val setupResult = runCommand(listOf("bash", setupSh.absolutePath, "--auto"), currentPath)
            printToConsole(console, setupResult.output + "\n", ConsoleViewContentType.NORMAL_OUTPUT)
            if (!setupResult.success) {
                printToConsole(console, "Setup finished with warnings (exit code: ${setupResult.exitCode}).\n" +
                    "You may need to configure config.env manually.\n\n", ConsoleViewContentType.ERROR_OUTPUT)
            } else {
                printToConsole(console, "Setup complete!\n\n", ConsoleViewContentType.NORMAL_OUTPUT)
            }
        }

        // Step 3: Proceed to review
        val reviewShPath = findReviewSh()
        if (reviewShPath != null) {
            printToConsole(console, "Starting review...\n\n", ConsoleViewContentType.NORMAL_OUTPUT)
            runReview(project, reviewShPath, prUrl)
        } else {
            printToConsole(console, "ERROR: review.sh still not found after install.\n" +
                "Check ~/claude-code-reviewer/ manually.\n", ConsoleViewContentType.ERROR_OUTPUT)
        }
    }

    private fun startReview(project: Project, reviewShPath: String, prUrl: String) {
        // Show tool window
        ApplicationManager.getApplication().invokeLater {
            val toolWindow = ToolWindowManager.getInstance(project).getToolWindow("Claude Reviewer")
            toolWindow?.show()
        }

        // Run on background thread
        ApplicationManager.getApplication().executeOnPooledThread {
            runReview(project, reviewShPath, prUrl)
        }
    }

    private fun runReview(project: Project, reviewShPath: String, prUrl: String) {
        val console = project.getUserData(ReviewToolWindowFactory.CONSOLE_KEY) ?: return

        ApplicationManager.getApplication().invokeLater {
            console.clear()
            console.print("=" .repeat(60) + "\n", ConsoleViewContentType.NORMAL_OUTPUT)
            console.print("Claude Review: $prUrl\n", ConsoleViewContentType.NORMAL_OUTPUT)
            console.print("=" .repeat(60) + "\n\n", ConsoleViewContentType.NORMAL_OUTPUT)
        }

        val cmd = GeneralCommandLine("bash", reviewShPath, prUrl)
            .withEnvironment("PATH", buildPath())
            .withCharset(Charsets.UTF_8)

        try {
            val handler = OSProcessHandler(cmd)
            ApplicationManager.getApplication().invokeLater {
                console.attachToProcess(handler)
            }

            handler.addProcessListener(object : ProcessAdapter() {
                override fun processTerminated(event: ProcessEvent) {
                    val code = event.exitCode
                    val type = if (code == 0) ConsoleViewContentType.NORMAL_OUTPUT
                               else ConsoleViewContentType.ERROR_OUTPUT
                    ApplicationManager.getApplication().invokeLater {
                        console.print("\nReview finished (exit code: $code)\n", type)
                        console.print("=" .repeat(60) + "\n", ConsoleViewContentType.NORMAL_OUTPUT)
                    }
                }
            })

            handler.startNotify()
            handler.waitFor()
        } catch (e: Exception) {
            ApplicationManager.getApplication().invokeLater {
                console.print("Error: ${e.message}\n", ConsoleViewContentType.ERROR_OUTPUT)
            }
        }
    }

    private fun printToConsole(console: ConsoleView, message: String, type: ConsoleViewContentType) {
        ApplicationManager.getApplication().invokeLater {
            console.print(message, type)
        }
    }

    private fun buildPath(): String {
        val currentPath = System.getenv("PATH") ?: ""
        return "$currentPath:/usr/local/bin:/opt/homebrew/bin"
    }

    private data class CommandResult(val success: Boolean, val output: String, val exitCode: Int)

    private fun runCommand(command: List<String>, path: String): CommandResult {
        return try {
            val pb = ProcessBuilder(command)
            pb.environment()["PATH"] = path
            pb.redirectErrorStream(true)
            val proc = pb.start()
            val output = proc.inputStream.bufferedReader().readText()
            val exitCode = proc.waitFor()
            CommandResult(exitCode == 0, output, exitCode)
        } catch (e: Exception) {
            CommandResult(false, e.message ?: "Unknown error", -1)
        }
    }

    private fun findReviewSh(): String? {
        // 1. Check environment variable override
        val envPath = System.getenv("CLAUDE_REVIEWER_PATH")
        if (envPath != null) {
            val f = File(envPath, "review.sh")
            if (f.exists()) return f.absolutePath
            val direct = File(envPath)
            if (direct.exists() && direct.name == "review.sh") return direct.absolutePath
        }

        val home = System.getProperty("user.home") ?: return null

        // 2. Check common locations
        val candidates = listOf(
            "$home/claude-code-reviewer/review.sh",
            "$home/.claude-code-reviewer/review.sh",
            "/usr/local/share/claude-code-reviewer/review.sh",
            "/opt/claude-code-reviewer/review.sh"
        )
        val found = candidates.firstOrNull { File(it).exists() }
        if (found != null) return found

        // 3. Scan ~/ for claude-code-reviewer directories (handles paths like ~/Truemeds 2.0/claude-code-reviewer)
        val homeDir = File(home)
        return findReviewShRecursive(homeDir, maxDepth = 3)
    }

    private fun findReviewShRecursive(dir: File, maxDepth: Int, currentDepth: Int = 0): String? {
        if (currentDepth > maxDepth) return null
        val skipDirs = setOf("Library", ".gradle", ".cache", "node_modules", ".git", ".m2", ".npm", ".local", "go")

        val reviewSh = File(dir, "claude-code-reviewer/review.sh")
        if (reviewSh.exists()) return reviewSh.absolutePath

        if (currentDepth < maxDepth) {
            val subdirs = dir.listFiles { f -> f.isDirectory && !f.isHidden && f.name !in skipDirs } ?: return null
            for (sub in subdirs) {
                val result = findReviewShRecursive(sub, maxDepth, currentDepth + 1)
                if (result != null) return result
            }
        }
        return null
    }
}
