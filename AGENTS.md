# AGENTS.md

This file provides guidance for agentic coding assistants working in this repository.

## Build, Lint, and Test Commands

### Building

This is a **pure Xcode project** with no command-line build system configured.

```bash
# Open in Xcode and build the LilAgents scheme
open lil-agents.xcodeproj
```

```bash
# Build via xcodebuild (requires Xcode)
xcodebuild -project lil-agents.xcodeproj -scheme LilAgents -configuration Debug build
xcodebuild -project lil-agents.xcodeproj -scheme LilAgents -configuration Release build
```

### Testing

**No test target exists.** The project has no unit tests or UI tests configured.

### Linting

**No linting tools are configured.** The project uses Xcode's built-in compiler warnings (see `project.pbxproj` for extensive `CLANG_WARN_*` settings).

### Code Signing

The project uses automatic code signing (`CODE_SIGN_STYLE = Automatic`). When building for distribution, ensure you have valid signing certificates configured in Xcode.

---

## Code Style Guidelines

### Architecture

- **Pattern**: Protocol-oriented design with concrete implementations
- **UI Framework**: AppKit (NSWindow, NSView, AVFoundation)
- **Concurrency**: Grand Central Dispatch (`DispatchQueue.main.async`)
- **Persistence**: UserDefaults for per-character settings and app preferences

### Project Structure

```
LilAgents/
├── LilAgentsApp.swift          # App entry point
├── LilAgentsController.swift    # Central coordinator (CVDisplayLink tick loop)
├── WalkerCharacter.swift        # Animated character with popover terminal
├── AgentSession.swift          # Protocol + AgentProvider enum
├── ClaudeSession.swift         # NDJSON streaming implementation
├── CodexSession.swift          # Codex CLI session
├── CopilotSession.swift        # Copilot CLI session
├── GeminiSession.swift         # Gemini CLI session
├── OpenCodeSession.swift       # OpenCode CLI session
├── ShellEnvironment.swift      # PATH resolution and process environment
├── TerminalView.swift         # Themed terminal with Markdown rendering
├── PopoverTheme.swift          # Centralized styling presets
└── CharacterContentView.swift  # NSView hosting AVPlayerLayer
```

### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Classes | PascalCase | `LilAgentsController`, `WalkerCharacter` |
| Structs | PascalCase | `PopoverTheme`, `AgentMessage` |
| Enums | PascalCase | `AgentProvider`, `TitleFormat` |
| Enum cases | camelCase | `.claude`, `.codex`, `.uppercase` |
| Properties | camelCase | `isRunning`, `positionProgress` |
| Methods | camelCase | `startWalk()`, `openPopover()` |
| Private helpers | camelCase prefixed with `_` or descriptive | `_handleInput()` |
| Constants | camelCase or PascalCase | `debugWindow`, `OnboardingKey` |

### Swift Style Rules

1. **Imports**: Group by framework, no unused imports
   ```swift
   import AppKit
   import AVFoundation
   ```

2. **Access Control**: Use `private` aggressively; `private(set)` for read-only public properties
   ```swift
   private var displayLink: CVDisplayLink?
   private(set) var isRunning = false
   ```

3. **Optionals**: Prefer `guard let` for early exit
   ```swift
   guard let path = path else { return }
   guard !text.isEmpty else { return }
   ```

4. **Closures**: Always capture `[weak self]` to avoid retain cycles
   ```swift
   proc.terminationHandler = { [weak self] _ in
       self?.handleTermination()
   }
   ```

5. **Self**: Use explicit `self` in closures and class methods
   ```swift
   characters.forEach { $0.controller = self }
   ```

6. **Mark Comments**: Use `// MARK: -` for code organization within files
   ```swift
   // MARK: - Setup
   // MARK: - Visibility
   // MARK: - Walking
   ```

7. **Error Handling**: Use `try?` for optional results, `do-catch` when errors matter
   ```swift
   guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
   ```

8. **Protocols**: Use `any AgentSession` for existential types
   ```swift
   var session: (any AgentSession)?
   ```

9. **Computed Properties**: Prefer computed over stored when logic is simple
   ```swift
   var displayWidth: CGFloat { displayHeight * (videoWidth / videoHeight) }
   ```

10. **Attributes**: Use `@discardableResult` when return value may be ignored
    ```swift
    @discardableResult
    private func updateEnvironmentVisibility(for screen: NSScreen) -> Bool
    ```

### AppKit Patterns

1. **Window Levels**: Characters use `NSWindow.Level.statusBar + i` sorted by x-position
2. **Display Link**: Use `CVDisplayLink` for animation frame updates, always invoke on main thread
3. **Frame Calculations**: Use `CGRect` and `NSPoint` for geometry; prefer `frame.origin.x` over `frame.minX`
4. **Layers**: Use `CATransaction.setDisableActions(true)` for programmatic animations

### Common Patterns

**Process spawning**:
```swift
let proc = Process()
proc.executableURL = URL(fileURLWithPath: binaryPath)
let pipe = Pipe()
proc.standardOutput = pipe
proc.terminationHandler = { [weak self] _ in ... }
try proc.run()
```

**Event monitors**:
```swift
clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
    self?.handleClickOutside()
}
```

**UserDefaults with fallback**:
```swift
var provider: AgentProvider {
    get {
        let raw = UserDefaults.standard.string(forKey: "\(name)Provider") ?? "claude"
        return AgentProvider(rawValue: raw) ?? .claude
    }
    set {
        UserDefaults.standard.set(newValue.rawValue, forKey: "\(name)Provider")
    }
}
```

### Things to Avoid

- Do NOT add comments explaining obvious code (per project convention)
- Do NOT commit `CLAUDECODE` or `CLAUDE_CODE_ENTRYPOINT` env vars in spawned processes
- Do NOT use force unwraps (`!`) except for IBOutlets or known-non-null system objects
- Do NOT create new files without checking existing patterns first
