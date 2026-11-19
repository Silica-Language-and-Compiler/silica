# Silica KISS Design Document

> **Superseded (2026-11-14, Lee).** The implementation steps in this design are no longer relevant and are not scheduled. The document is kept for the record.

## 1. Purpose

Silica KISS is a lightweight macOS development application for working on the Silica programming language and its compiler.

The app is intended primarily for personal use. It is not a general-purpose IDE. It should provide a focused environment for editing Silica source code, browsing project files, running compiler-related system commands, viewing command output, and using AI assistance through OpenRouter.

The app should feel like a small, purpose-built development cockpit rather than a full editor platform.

## 2. Goals

The application should provide:

1. A native macOS application.
2. A project file browser on the left.
3. A source editor in the main area.
4. Silica syntax colorization loaded from editable external configuration files.
5. A bottom panel for command output, errors, and logs.
6. Buttons and keyboard shortcuts for common compiler-development actions.
7. A way to enter and securely store an OpenRouter API key.
8. A way to fetch, display, select, and switch between OpenRouter models.
9. An AI assistant panel that can use the selected OpenRouter model.
10. The ability to send source code, compiler output, selected text, or file context to the AI assistant.

## 3. Non-goals

The first version should not attempt to be:

1. A full Cursor clone.
2. A full VS Code replacement.
3. A general plugin platform.
4. A complete language-server-based IDE.
5. A collaborative editor.
6. A cloud-synced application.
7. A multi-user application.
8. A browser-based application.

The app should favor simple, understandable native implementation over generality.

## 4. Target Platform

The primary platform is macOS.

Recommended implementation stack:

```text
Swift
SwiftUI
AppKit interop where needed
NSTextView or a lightweight native code editor component
Foundation.Process for command execution
URLSession for OpenRouter HTTP calls
Keychain for API key storage
```

The initial version should use `NSTextView` through `NSViewRepresentable`, unless a third-party code editor component becomes necessary later.

## 5. High-Level Application Layout

The main window should use a three-region layout:

```text
┌─────────────────────────────────────────────────────────────┐
│ Toolbar: Build | Test | Run | Model Picker | Ask AI          │
├───────────────────┬─────────────────────────────────────────┤
│ File Browser      │ Source Editor                           │
│                   │                                         │
│ Project tree      │ Tabs or single open file                │
│                   │                                         │
├───────────────────┴─────────────────────────────────────────┤
│ Output / Errors / Terminal / AI Assistant                   │
└─────────────────────────────────────────────────────────────┘
```

A later version may add a right-side AI panel, but the first version can use the bottom panel with tabs.

Suggested bottom panel tabs:

```text
Output
Errors
Generated Assembly
AI Assistant
OpenRouter
```

## 6. Core Components

### 6.1 Project Manager

Responsible for:

1. Opening a project folder.
2. Remembering the last opened folder.
3. Discovering files in the folder.
4. Filtering ignored files.
5. Providing the file tree to the sidebar.
6. Tracking the project root for command execution.

The app should support a project configuration file, for example:

```json
{
  "name": "Silica",
  "sourceExtensions": ["si", "silica"],
  "commands": {
    "buildCompiler": "cargo build",
    "testCompiler": "cargo test",
    "compileCurrentFile": "cargo run -- compile ${file}",
    "runCurrentOutput": "./${fileBasenameNoExtension}"
  },
  "diagnosticPattern": "^(.*):(\\d+):(\\d+):\\s*(error|warning):\\s*(.*)$"
}
```

Suggested filename:

```text
.silica-KISS.json
```

If the project file does not exist, the app should use sensible hardcoded defaults.

### 6.2 File Browser

The file browser should:

1. Show the current project directory.
2. Display folders and files hierarchically.
3. Hide build artifacts and dependency folders by default.
4. Let the user open a file by clicking it.
5. Indicate unsaved changes.
6. Optionally support file creation, rename, and delete later.

Default hidden entries:

```text
.git
target
build
DerivedData
.DS_Store
```

### 6.3 Source Editor

The editor should initially use an AppKit `NSTextView` wrapped for SwiftUI.

Required features:

1. Open text files.
2. Edit text.
3. Save text.
4. Track dirty state.
5. Use a monospaced font.
6. Support syntax colorization.
7. Support line and column tracking.
8. Support jump-to-line for diagnostics.

Nice-to-have features:

1. Line numbers.
2. Current-line highlight.
3. Matching bracket highlight.
4. Multiple editor tabs.
5. Split view for source and generated assembly.

### 6.4 Syntax Colorization

Syntax colorization should be externally configurable so that changes do not require recompiling the app.

Use two files:

```text
~/Library/Application Support/Silica KISS/silica.tmLanguage.json
~/Library/Application Support/Silica KISS/silica.theme.json
```

The app bundle should include default copies:

```text
SilicaKISS.app/Contents/Resources/silica.tmLanguage.json
SilicaKISS.app/Contents/Resources/silica.theme.json
```

On first launch, the app should copy the bundled defaults into Application Support. The user-editable copies in Application Support should take precedence over bundled defaults.

The grammar file controls what tokens are recognized.

The theme file controls colors and styles.

Example theme file:

```json
{
  "name": "Silica Default Dark",
  "colors": {
    "foreground": "#D4D4D4",
    "background": "#1E1E1E",
    "selection": "#264F78"
  },
  "tokenColors": {
    "comment.line.double-slash.silica": {
      "foreground": "#6A9955"
    },
    "comment.block.silica": {
      "foreground": "#6A9955"
    },
    "keyword.control.silica": {
      "foreground": "#569CD6"
    },
    "keyword.other.silica": {
      "foreground": "#C586C0"
    },
    "constant.language.silica": {
      "foreground": "#569CD6"
    },
    "storage.type.silica": {
      "foreground": "#4EC9B0"
    },
    "storage.type.annotation.silica": {
      "foreground": "#4EC9B0"
    },
    "entity.name.function.silica": {
      "foreground": "#DCDCAA"
    },
    "string.quoted.double.silica": {
      "foreground": "#CE9178"
    },
    "string.quoted.single.silica": {
      "foreground": "#CE9178"
    },
    "constant.character.escape.silica": {
      "foreground": "#D7BA7D"
    },
    "constant.other.symbol.silica": {
      "foreground": "#B5CEA8"
    },
    "constant.numeric.silica": {
      "foreground": "#B5CEA8"
    },
    "constant.numeric.hex.silica": {
      "foreground": "#B5CEA8"
    },
    "constant.numeric.binary.silica": {
      "foreground": "#B5CEA8"
    },
    "keyword.operator.arrow.silica": {
      "foreground": "#C586C0"
    },
    "keyword.operator.silica": {
      "foreground": "#D4D4D4"
    },
    "meta.effect.silica": {
      "foreground": "#9CDCFE"
    },
    "keyword.other.effect.silica": {
      "foreground": "#9CDCFE"
    },
    "markup.bold markup.italic keyword.other.dangerous.silica": {
      "foreground": "#F44747",
      "fontStyle": "bold italic"
    }
  }
}
```

The first implementation does not need a complete TextMate engine. It only needs to support the subset used by the Silica grammar:

```text
repository
patterns
include
name
match
begin
end
captures
nested patterns
```

For version 0, captures may be skipped. For version 1, captures should be supported so that type annotations can color the arrow or colon separately from the type name.

The highlighter should avoid recoloring keywords inside comments and strings. A simple approach is:

```text
1. Reset whole document to default attributes.
2. Highlight comments, strings, and character literals.
3. Record those ranges as protected.
4. Apply all other rules only to ranges that do not intersect protected ranges.
```

The app should provide a menu item:

```text
Developer → Reload Syntax Files
```

This reloads the grammar and theme files without restarting the app.

Later, the app may use file-system watching to auto-reload the grammar and theme when changed.

### 6.5 Command Runner

The command runner should execute shell commands in the project root.

Use `Foundation.Process`.

Basic command execution model:

```text
Command name
Shell command string
Working directory
Environment variables
stdout stream
stderr stream
exit code
start time
end time
```

Commands should run through the user’s shell for convenience:

```text
/bin/zsh -lc "<command>"
```

This allows commands such as:

```text
cargo build
cargo test
cargo run -- compile examples/hello.si
clang output.s -o output
./output
```

The command runner should stream output into the bottom panel while the command runs.

The command runner should support cancellation.

Suggested default commands:

```text
Build Compiler      cargo build
Test Compiler       cargo test
Compile File        cargo run -- compile ${file}
Run Output          ./${fileBasenameNoExtension}
Clean               cargo clean
```

Supported substitutions:

```text
${projectRoot}
${file}
${fileName}
${fileBasename}
${fileBasenameNoExtension}
${fileDirectory}
```

### 6.6 Diagnostics Parser

The app should parse compiler output into diagnostics.

A diagnostic should have:

```text
file path
line
column
severity
message
raw line
```

Supported severities:

```text
error
warning
note
info
```

The project configuration should define a regex pattern for diagnostics.

Example:

```json
{
  "diagnosticPattern": "^(.*):(\\d+):(\\d+):\\s*(error|warning):\\s*(.*)$"
}
```

The Errors tab should display diagnostics in a list. Clicking a diagnostic should open the file and jump to the location.

## 7. OpenRouter Integration

The app should use OpenRouter for AI assistance.

OpenRouter provides an OpenAI-compatible API. The app should use direct HTTP calls rather than depending on a third-party SDK.

Base URL:

```text
https://openrouter.ai/api/v1
```

Primary endpoints:

```text
GET  /models
GET  /key
POST /chat/completions
```

The app should treat the OpenRouter API key as user-owned secret data.

### 7.1 API Key Entry

On first launch, or when the user opens AI settings, the app should show an OpenRouter API key entry screen.

Suggested UI:

```text
OpenRouter Settings

[ API Key:  ******************************** ]

Buttons:
[ Save Key ] [ Test Key ] [ Clear Key ]

Status:
Not configured / Valid / Invalid / Network error / Insufficient credits
```

The app should not store the key in UserDefaults or a plain text config file.

Store the key in macOS Keychain.

Suggested Keychain metadata:

```text
service: SilicaKISS.OpenRouter
account: default
```

The API key should be loaded from Keychain when the app starts.

The user should be able to replace or delete the stored key at any time.

### 7.2 Testing the API Key

The app should test the API key using:

```http
GET https://openrouter.ai/api/v1/key
Authorization: Bearer <OPENROUTER_API_KEY>
```

The result should be displayed in the settings panel.

If the key is invalid, the app should show a clear error.

If the key is valid, the app should optionally show available credit or usage information if returned by the API.

### 7.3 Model Discovery

The app should fetch available OpenRouter models using:

```http
GET https://openrouter.ai/api/v1/models
Authorization: Bearer <OPENROUTER_API_KEY>
```

The model list should be cached locally.

A model entry should include at least:

```text
id
name
description
context length
pricing, if available
supported parameters, if available
architecture or modality metadata, if available
```

The app should use the model `id` when sending chat requests.

Examples of model IDs may look like:

```text
openai/gpt-4o
anthropic/claude-sonnet-4
google/gemini-pro
meta-llama/llama-3.1-70b-instruct
```

Actual IDs must come from the OpenRouter models endpoint, not from hardcoded assumptions.

### 7.4 Model Picker

The toolbar should include a model picker.

Suggested UI:

```text
Model: [ openai/gpt-4o             v ]
```

The picker should support:

1. Search by model name.
2. Search by provider.
3. Favorites.
4. Recently used models.
5. Context-length display.
6. Price display if available.
7. Refresh model list.

Suggested model browser layout:

```text
Search: [ claude                     ]

Favorites
  anthropic/claude-sonnet-4

All Models
  openai/gpt-4o
  anthropic/claude-sonnet-4
  google/gemini-pro
  mistralai/mistral-large
```

Selecting a model should update the current AI session configuration.

The current model should be persisted in app settings.

Suggested UserDefaults key:

```text
selectedOpenRouterModelID
```

### 7.5 Switching Models

Switching models should be allowed at any time.

When the user switches models during an AI conversation, the app should preserve the conversation history but send future requests to the newly selected model.

The conversation transcript should record which model produced each response.

Example internal message record:

```swift
struct AIMessage {
    let id: UUID
    let role: AIRole
    let content: String
    let modelID: String?
    let createdAt: Date
}
```

For user messages, `modelID` is nil.

For assistant messages, `modelID` is the model that generated the response.

The UI should show the model near each assistant response:

```text
Assistant — openai/gpt-4o
```

### 7.6 Chat Completion Request

The app should use:

```http
POST https://openrouter.ai/api/v1/chat/completions
Authorization: Bearer <OPENROUTER_API_KEY>
Content-Type: application/json
HTTP-Referer: https://github.com/yenrab/silica
X-Title: Silica KISS
```

The `HTTP-Referer` and `X-Title` headers are optional but useful for identifying the app to OpenRouter.

Example request:

```json
{
  "model": "openai/gpt-4o",
  "messages": [
    {
      "role": "system",
      "content": "You are assisting with development of the Silica programming language and its compiler. Be precise, concise, and explain compiler-related reasoning clearly."
    },
    {
      "role": "user",
      "content": "Explain this compiler error and suggest a fix."
    }
  ],
  "temperature": 0.2,
  "stream": true
}
```

The model field should always come from the currently selected model.

### 7.7 Streaming Responses

The app should use streaming for AI responses.

Request:

```json
{
  "model": "openai/gpt-4o",
  "messages": [],
  "stream": true
}
```

The response should be consumed as server-sent events.

The UI should update the assistant response incrementally as tokens arrive.

The app should provide a Cancel button that stops the request.

### 7.8 AI Assistant Context

The app should make it easy to send useful development context to the selected model.

Supported context actions:

```text
Ask about selection
Ask about current file
Ask about compiler output
Ask about selected error
Explain generated assembly
Suggest a compiler fix
Generate a Silica test case
Summarize this module
```

The AI request builder should assemble messages from:

```text
system prompt
conversation history
selected source text
current file path
compiler output
diagnostic details
generated assembly
user question
```

Example prompt for selected code:

```text
File: examples/hello.si

Selected Silica source:

<source>
...
</source>

Question:
Explain what this code does and identify any likely compiler issues.
```

Example prompt for compiler output:

```text
I am developing the Silica compiler.

Command:
cargo run -- compile examples/hello.si

Compiler output:
<output>
...
</output>

Current source file:
<source>
...
</source>

Question:
Explain the error and suggest the smallest fix.
```

### 7.9 AI Safety and Control

Because the app can run system commands, the AI assistant must not automatically execute commands.

The app should distinguish:

```text
AI suggestion
User-approved command
Actual command execution
```

The AI can suggest commands, but the app should require explicit user action before running anything.

Example UI:

```text
Suggested command:

cargo test parser::tests::parse_actor

[ Copy ] [ Run ]
```

The Run button should be user-controlled.

No AI-generated command should run automatically.

### 7.10 OpenRouter Error Handling

The OpenRouter client should handle:

```text
missing API key
invalid API key
network failure
rate limit
insufficient credits
model unavailable
provider error
context length exceeded
malformed response
stream interrupted
```

The UI should show useful messages, not raw JSON only.

Examples:

```text
OpenRouter API key is missing. Add one in Settings → OpenRouter.

The selected model is unavailable. Refresh models or choose a different model.

The request exceeded the model’s context limit. Try sending less source context.

The request was rate-limited. Try again later or select another model.
```

### 7.11 Local OpenRouter Client Design

Suggested Swift types:

```swift
struct OpenRouterClient {
    let apiKeyProvider: APIKeyProvider
    let baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!

    func fetchKeyInfo() async throws -> OpenRouterKeyInfo
    func fetchModels() async throws -> [OpenRouterModel]
    func streamChatCompletion(
        request: OpenRouterChatRequest,
        onDelta: @escaping (String) -> Void
    ) async throws -> OpenRouterChatResult
}
```

Model type:

```swift
struct OpenRouterModel: Codable, Identifiable {
    let id: String
    let name: String?
    let description: String?
    let contextLength: Int?
    let pricing: OpenRouterPricing?
}
```

Request type:

```swift
struct OpenRouterChatRequest: Codable {
    let model: String
    let messages: [OpenRouterMessage]
    let temperature: Double?
    let stream: Bool
}
```

Message type:

```swift
struct OpenRouterMessage: Codable {
    let role: String
    let content: String
}
```

### 7.12 Keychain Storage

Use Keychain for the OpenRouter key.

Suggested abstraction:

```swift
protocol APIKeyStore {
    func readOpenRouterKey() throws -> String?
    func saveOpenRouterKey(_ key: String) throws
    func deleteOpenRouterKey() throws
}
```

The app should avoid logging the key.

The app should avoid showing the full key after it is saved.

The UI may show a masked version:

```text
sk-or-v1-••••••••••••••••••••abcd
```

### 7.13 Model Cache

The model list should be cached so the app can launch quickly.

Suggested cache file:

```text
~/Library/Application Support/Silica KISS/openrouter-models-cache.json
```

Cache metadata:

```json
{
  "fetchedAt": "2026-06-15T10:00:00Z",
  "models": []
}
```

The app should refresh models:

```text
manually by user action
automatically if cache is older than 24 hours
after API key changes
```

If refresh fails, the app should continue using the cached model list if available.

## 8. Settings

The app should have a Settings window with these sections:

```text
General
Editor
Syntax
Commands
OpenRouter
```

### 8.1 General Settings

```text
Default project folder
Restore last project on launch
Show hidden files
```

### 8.2 Editor Settings

```text
Font family
Font size
Tab width
Use spaces for tabs
Show line numbers
Highlight current line
```

### 8.3 Syntax Settings

```text
Grammar file path
Theme file path
Reload syntax files
Open syntax folder
```

### 8.4 Command Settings

```text
Build command
Test command
Compile current file command
Run current output command
Diagnostic regex
```

### 8.5 OpenRouter Settings

```text
API key
Test key
Clear key
Refresh model list
Default model
Temperature
Stream responses
Show pricing in model picker
```

## 9. Data Storage

Suggested local storage:

```text
~/Library/Application Support/Silica KISS/
├── silica.tmLanguage.json
├── silica.theme.json
├── openrouter-models-cache.json
├── settings.json
└── logs/
```

Use Keychain for:

```text
OpenRouter API key
```

Use UserDefaults for simple preferences:

```text
lastProjectPath
selectedOpenRouterModelID
editorFontSize
bottomPanelHeight
```

## 10. Security Considerations

The app will have two sensitive capabilities:

1. It stores an OpenRouter API key.
2. It runs local shell commands.

Security rules:

1. Store API keys only in Keychain.
2. Never log API keys.
3. Never include API keys in crash reports.
4. Never run AI-generated commands automatically.
5. Show commands before running them.
6. Run commands only in the project directory by default.
7. Make destructive commands visible and user-approved.
8. Do not upload entire projects to AI unless the user explicitly asks.
9. Make it clear what context is being sent to OpenRouter.

The AI assistant panel should show a context preview before sending large source content.

## 11. First-Version Feature Set

Version 0 should include:

```text
Open folder
File browser
Open/edit/save files
NSTextView-based editor
External syntax grammar file
External theme file
Build command
Test command
Compile current file command
Bottom output panel
OpenRouter key entry
Keychain storage
OpenRouter key test
Fetch OpenRouter model list
Model picker
Basic AI chat using selected model
Streaming AI responses
Ask about selected text
Ask about compiler output
```

Version 0 should not include:

```text
full TextMate compatibility
language server
autocomplete
inline AI edits
automatic patch application
multi-project workspaces
debugger integration
```

## 12. Version 1 Enhancements

Version 1 may add:

```text
line numbers
diagnostic parsing
click error to jump to source
generated assembly panel
favorites in model picker
model search/filtering
command history
reload syntax files menu item
file-system watching for syntax files
AI prompt templates
AI-generated patch preview
```

## 13. Version 2 Enhancements

Version 2 may add:

```text
Silica language server support
symbol browser
go to definition
find references
inline diagnostics
code folding
Tree-sitter or compiler-token based highlighting
side-by-side source and assembly
AI-assisted refactoring with explicit patch review
```

## 14. Suggested Implementation Order

### Step 1: App Shell

Build the main SwiftUI window:

```text
NavigationSplitView or HSplitView
file browser placeholder
editor placeholder
bottom output panel
toolbar
```

### Step 2: Project Opening

Implement:

```text
open folder
remember folder
list files
click file to open
```

### Step 3: Editor

Implement:

```text
NSTextView wrapper
load file contents
edit
save
dirty flag
```

### Step 4: Commands

Implement:

```text
run shell command
stream output
show exit code
cancel running command
```

### Step 5: Syntax Colorization

Implement:

```text
load grammar JSON
load theme JSON
compile regex rules
apply colors
reload syntax files
```

### Step 6: OpenRouter Key

Implement:

```text
OpenRouter settings panel
API key entry
Keychain save/load/delete
test key using /key endpoint
```

### Step 7: Model Discovery

Implement:

```text
fetch /models
cache model list
display model picker
persist selected model
```

### Step 8: AI Chat

Implement:

```text
chat request builder
POST /chat/completions
streaming response
AI Assistant tab
selected model support
```

### Step 9: Context-Aware AI Actions

Implement:

```text
ask about selection
ask about current file
ask about compiler output
ask about selected diagnostic
```

## 15. Example OpenRouter HTTP Requests

### 15.1 Test API Key

```http
GET /api/v1/key HTTP/1.1
Host: openrouter.ai
Authorization: Bearer <OPENROUTER_API_KEY>
```

### 15.2 Fetch Models

```http
GET /api/v1/models HTTP/1.1
Host: openrouter.ai
Authorization: Bearer <OPENROUTER_API_KEY>
```

### 15.3 Send Chat Completion

```http
POST /api/v1/chat/completions HTTP/1.1
Host: openrouter.ai
Authorization: Bearer <OPENROUTER_API_KEY>
Content-Type: application/json
HTTP-Referer: https://github.com/yenrab/silica
X-Title: Silica KISS

{
  "model": "openai/gpt-4o",
  "messages": [
    {
      "role": "system",
      "content": "You are assisting with development of the Silica programming language and its compiler."
    },
    {
      "role": "user",
      "content": "Explain this compiler error."
    }
  ],
  "temperature": 0.2,
  "stream": true
}
```

## 16. Swift Implementation Sketch

### 16.1 OpenRouter Client

```swift
import Foundation

final class OpenRouterClient {
    private let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    private let apiKeyStore: APIKeyStore

    init(apiKeyStore: APIKeyStore) {
        self.apiKeyStore = apiKeyStore
    }

    private func makeRequest(path: String, method: String = "GET") throws -> URLRequest {
        guard let apiKey = try apiKeyStore.readOpenRouterKey(), !apiKey.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Silica KISS", forHTTPHeaderField: "X-Title")
        request.setValue("https://github.com/yenrab/silica", forHTTPHeaderField: "HTTP-Referer")
        return request
    }

    func fetchModels() async throws -> [OpenRouterModel] {
        let request = try makeRequest(path: "models")
        let (data, response) = try await URLSession.shared.data(for: request)

        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
        return decoded.data
    }

    func fetchKeyInfo() async throws -> OpenRouterKeyInfo {
        let request = try makeRequest(path: "key")
        let (data, response) = try await URLSession.shared.data(for: request)

        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(OpenRouterKeyInfoResponse.self, from: data)
        return decoded.data
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenRouterError.httpError(statusCode: http.statusCode, body: body)
        }
    }
}
```

### 16.2 Chat Request

```swift
struct OpenRouterChatRequest: Encodable {
    let model: String
    let messages: [OpenRouterMessage]
    let temperature: Double
    let stream: Bool
}

struct OpenRouterMessage: Codable {
    let role: String
    let content: String
}
```

### 16.3 Model Response

```swift
struct OpenRouterModelsResponse: Decodable {
    let data: [OpenRouterModel]
}

struct OpenRouterModel: Decodable, Identifiable {
    let id: String
    let name: String?
    let description: String?
    let contextLength: Int?
    let pricing: OpenRouterPricing?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case contextLength = "context_length"
        case pricing
    }
}

struct OpenRouterPricing: Decodable {
    let prompt: String?
    let completion: String?
}
```

### 16.4 Error Type

```swift
enum OpenRouterError: Error {
    case missingAPIKey
    case invalidResponse
    case httpError(statusCode: Int, body: String)
}
```

## 17. Open Questions

1. Should AI chat live in the bottom panel or a right sidebar?
2. Should the app support multiple open files in tabs for version 0?
3. Should generated assembly be treated as a normal file or as a special output pane?
4. Should command definitions be global, project-local, or both?
5. Should the syntax grammar use a TextMate subset permanently, or should the app eventually use Silica’s compiler lexer?
6. Should the app include a built-in default OpenRouter model, or require the user to choose one after fetching the model list?

## 18. Recommended Initial Decisions

For the first implementation:

```text
Use SwiftUI + NSTextView.
Use external grammar and theme files.
Use Keychain for the OpenRouter key.
Use direct URLSession calls to OpenRouter.
Use /models for model discovery.
Use /key to test the API key.
Use /chat/completions with streaming for AI responses.
Use a toolbar model picker.
Use a bottom AI Assistant tab.
Require explicit user approval before running commands.
```

This keeps the app small, native, understandable, and focused on Silica compiler development.
