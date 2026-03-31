import Foundation

class OpenClawSession: AgentSession {
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
    private var typewriterGeneration = 0

    // MARK: - Lifecycle

    func start() {
        if Self.binaryPath != nil {
            isRunning = true
            onSessionReady?()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "openclaw", fallbackPaths: [
            "\(home)/.local/bin/openclaw",
            "\(home)/go/bin/openclaw",
            "/usr/local/bin/openclaw",
            "/opt/homebrew/bin/openclaw"
        ]) { [weak self] path in
            guard let self = self else { return }
            if let binaryPath = path {
                Self.binaryPath = binaryPath
                self.isRunning = true
                self.onSessionReady?()
            } else {
                let msg = "OpenClaw CLI not found.\n\n\(AgentProvider.openclaw.installInstructions)"
                self.onError?(msg)
                self.history.append(AgentMessage(role: .error, text: msg))
            }
        }
    }

    func send(message: String) {
        guard isRunning, let binaryPath = Self.binaryPath else { return }
        isBusy = true
        currentResponseText = ""
        typewriterGeneration += 1
        history.append(AgentMessage(role: .user, text: message))
        lineBuffer = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        // Use --agent main as default, can be overridden via OPENCLAW_DEFAULT_AGENT env var
        let defaultAgent = ProcessInfo.processInfo.environment["OPENCLAW_DEFAULT_AGENT"] ?? "main"
        proc.arguments = ["agent", "--local", "--json", "--agent", defaultAgent, "--message", message]
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
                DispatchQueue.main.async {
                    self?.processOutput(text)
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
            let msg = "Failed to launch OpenClaw CLI: \(error.localizedDescription)"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    func terminate() {
        typewriterGeneration += 1
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

        // Process all complete JSON objects in the buffer
        while true {
            // Find the start of a JSON object
            guard let jsonStart = lineBuffer.range(of: "{") else {
                // No JSON start found, clear the buffer (discard non-JSON output)
                lineBuffer = ""
                return
            }

            // Remove everything before the JSON start (discard non-JSON prefix)
            if jsonStart.lowerBound != lineBuffer.startIndex {
                lineBuffer = String(lineBuffer[jsonStart.lowerBound...])
            }

            // Try to find the matching closing brace
            guard let jsonEnd = findJSONEnd(in: lineBuffer) else {
                // Incomplete JSON, wait for more data
                return
            }

            // Extract the complete JSON
            let jsonStr = String(lineBuffer[..<jsonEnd])
            lineBuffer = String(lineBuffer[jsonEnd...])

            // Parse and handle the JSON (only extract text, don't display raw JSON)
            parseJSONResponse(jsonStr)
        }
    }

    private func findJSONEnd(in text: String) -> String.Index? {
        var bracketCount = 0
        var inString = false
        var escape = false

        for index in text.indices {
            let char = text[index]

            if escape {
                escape = false
                continue
            }

            if char == "\\" {
                escape = true
                continue
            }

            if char == "\"" {
                inString.toggle()
                continue
            }

            if !inString {
                if char == "{" {
                    bracketCount += 1
                } else if char == "}" {
                    bracketCount -= 1
                    if bracketCount == 0 {
                        return text.index(after: index)
                    }
                }
            }
        }

        return nil
    }

    private func parseJSONResponse(_ line: String) {
        guard let rawData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            // Debug: print failed parse attempts
            #if DEBUG
            print("[OpenClaw] Failed to parse JSON: \(line.prefix(100))")
            #endif
            return
        }

        // Handle openclaw agent --json format
        if let payloads = json["payloads"] as? [[String: Any]] {
            #if DEBUG
            print("[OpenClaw] Found \(payloads.count) payload(s)")
            #endif
            for payload in payloads {
                if let text = payload["text"] as? String, !text.isEmpty {
                    #if DEBUG
                    print("[OpenClaw] Extracted text: \(text)")
                    #endif
                    currentResponseText += text
                    emitTypewriter(text)
                }
            }
            // Done with payloads
            isBusy = false
            onTurnComplete?()
            return
        }

        // Fallback: Handle streaming JSON format (type-based)
        let type = json["type"] as? String ?? ""

        switch type {
        case "text", "content":
            if let content = json["content"] as? String {
                currentResponseText += content
                emitTypewriter(content)
            } else if let part = json["part"] as? [String: Any],
               let text = part["text"] as? String {
                currentResponseText += text
                emitTypewriter(text)
            }

        case "step_start":
            isBusy = true

        case "step_finish":
            break

        case "result", "done":
            isBusy = false
            onTurnComplete?()

        case "tool_call":
            let toolName = json["name"] as? String ?? "Tool"
            let input = json["arguments"] as? [String: Any] ?? [:]
            history.append(AgentMessage(role: .toolUse, text: "\(toolName)"))
            onToolUse?(toolName, input)

        case "tool_result":
            let output = json["result"] as? String ?? ""
            let isError = (json["status"] as? String == "error")
            let summary = String(output.prefix(80))
            history.append(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
            onToolResult?(summary, isError)

        default:
            break
        }
    }

    // MARK: - Typewriter

    private func emitTypewriter(_ text: String) {
        let chunks = typewriterChunks(text)
        let generation = typewriterGeneration
        let intervalMs = 18
        for (i, chunk) in chunks.enumerated() {
            let delay = DispatchTimeInterval.milliseconds(i * intervalMs)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.typewriterGeneration == generation else { return }
                self.onText?(chunk)
            }
        }
    }

    private func typewriterChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if char == " " || char == "\n" {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
