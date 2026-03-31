import Foundation

class OpenCodeSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private var currentResponseText = ""
    private(set) var isRunning = false
    private(set) var isBusy = false
    private static var binaryPath: String?

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    var history: [AgentMessage] = []

    // MARK: - Lifecycle

    func start() {
        if Self.binaryPath != nil {
            isRunning = true
            onSessionReady?()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "opencode", fallbackPaths: [
            "\(home)/.local/bin/opencode",
            "/usr/local/bin/opencode",
            "/opt/homebrew/bin/opencode"
        ]) { [weak self] path in
            guard let self = self else { return }
            if let binaryPath = path {
                Self.binaryPath = binaryPath
                self.isRunning = true
                self.onSessionReady?()
            } else {
                let msg = "OpenCode CLI not found.\n\n\(AgentProvider.opencode.installInstructions)"
                self.onError?(msg)
                self.history.append(AgentMessage(role: .error, text: msg))
            }
        }
    }

    func send(message: String) {
        guard isRunning, let binaryPath = Self.binaryPath else { return }
        isBusy = true
        currentResponseText = ""
        history.append(AgentMessage(role: .user, text: message))
        lineBuffer = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["run", message, "--format", "json"]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ShellEnvironment.processEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil

                if !self.currentResponseText.isEmpty {
                    self.history.append(AgentMessage(role: .assistant, text: self.currentResponseText))
                }

                if self.isBusy {
                    self.isBusy = false
                    self.onTurnComplete?()
                }

                self.onProcessExit?()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.processOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                let filtered = text.components(separatedBy: "\n").filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return false }
                    if trimmed.hasPrefix("\u{001B}[") { return false }
                    if trimmed.hasPrefix("✓") || trimmed.hasPrefix("→") ||
                       trimmed.hasPrefix("◆") || trimmed.contains("[plugins]") ||
                       trimmed.contains("[agent/") || trimmed.contains("[ws-") { return false }
                    return true
                }.joined(separator: "\n")
                if !filtered.isEmpty {
                    DispatchQueue.main.async {
                        self?.onError?(filtered)
                    }
                }
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = outPipe
            errorPipe = errPipe
        } catch {
            isBusy = false
            let msg = "Failed to launch OpenCode CLI: \(error.localizedDescription)"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    func terminate() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        isBusy = false
    }

    // MARK: - JSONL Parsing

    private func processOutput(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            if !line.isEmpty {
                parseLine(line)
            }
        }
    }

    private func parseLine(_ line: String) {
        guard let rawData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            return
        }

        if let payloads = json["payloads"] as? [[String: Any]] {
            for payload in payloads {
                if let text = payload["text"] as? String, !text.isEmpty {
                    currentResponseText += text
                    onText?(text)
                }
            }
            if json["meta"] != nil {
                isBusy = false
                onTurnComplete?()
            }
            return
        }

        let type = json["type"] as? String ?? ""

        switch type {
        case "text":
            if let part = json["part"] as? [String: Any],
               let text = part["text"] as? String {
                currentResponseText += text
                onText?(text)
            }

        case "step_start":
            isBusy = true

        case "step_finish":
            break

        case "result":
            isBusy = false
            onTurnComplete?()

        case "assistant.tool_call":
            let part = json["part"] as? [String: Any] ?? [:]
            let toolName = part["name"] as? String ?? "Tool"
            let input = part["arguments"] as? [String: Any] ?? [:]
            history.append(AgentMessage(role: .toolUse, text: "\(toolName)"))
            onToolUse?(toolName, input)

        case "assistant.tool_result":
            let part = json["part"] as? [String: Any] ?? [:]
            let output = part["result"] as? String ?? ""
            let isError = (part["status"] as? String == "error")
            let summary = String(output.prefix(80))
            history.append(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
            onToolResult?(summary, isError)

        default:
            break
        }
    }
}
