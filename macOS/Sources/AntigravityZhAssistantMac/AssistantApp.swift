import AppKit
import SwiftUI
import Foundation
import Darwin

private let appName = "Antigravity 中文助手"
private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.6.42"
private let manifestURL = URL(string: "https://raw.githubusercontent.com/CX-ARTLab/antigravity-zh-assistant/main/translation/manifest.json")!

private func assistantIconImage() -> NSImage {
    if let bundled = Bundle.main.url(forResource: "assistant-icon", withExtension: "png"),
       let image = NSImage(contentsOf: bundled) { return image }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let repositoryRoot = cwd.lastPathComponent == "macOS" ? cwd.deletingLastPathComponent() : cwd
    let candidates = [
        cwd.appendingPathComponent("Resources/assistant-icon.png"),
        repositoryRoot.appendingPathComponent("macOS/Resources/assistant-icon.png"),
        repositoryRoot.appendingPathComponent("src/Assets/assistant-icon.png")
    ]
    for url in candidates {
        if let image = NSImage(contentsOf: url) { return image }
    }
    return NSImage(size: NSSize(width: 64, height: 64))
}

private enum AssistantError: LocalizedError {
    case noDebugPort
    case noTarget
    case invalidResponse
    case notInstalled
    case restartRequired

    var errorDescription: String? {
        switch self {
        case .noDebugPort: return "点击「启动并汉化」以打开 Antigravity。"
        case .noTarget: return "还没找到 Antigravity 主窗口。窗口加载后请重试。"
        case .invalidResponse: return "Antigravity 调试接口返回了无效响应。"
        case .notInstalled: return "未找到 Antigravity 桌面应用。"
        case .restartRequired: return "请在 Antigravity 中保存工作并退出，然后回到助手点击「启动并汉化」。"
        }
    }
}

private enum DevToolsTarget {
    case socket(URL)
    case pipe(PrivateDevTools, targetID: String)
}

private final class CDPClient {
    private enum Connection {
        case socket(URLSessionWebSocketTask)
        case pipe(PrivateDevTools, sessionID: String)
    }

    private let connection: Connection
    private var nextID = 1

    init(target: DevToolsTarget) async throws {
        switch target {
        case .socket(let url):
            let socket = URLSession.shared.webSocketTask(with: url)
            socket.resume()
            connection = .socket(socket)
        case .pipe(let pipe, let targetID):
            let reply = try await pipe.request("Target.attachToTarget", params: ["targetId": targetID, "flatten": true])
            guard let sessionID = reply["sessionId"] as? String else { throw AssistantError.invalidResponse }
            connection = .pipe(pipe, sessionID: sessionID)
        }
    }

    func evaluate(_ expression: String) async throws -> Any? {
        let params: [String: Any] = ["expression": expression, "returnByValue": true, "awaitPromise": false]
        let result: [String: Any]
        switch connection {
        case .socket(let socket):
            result = try await sendViaSocket(socket, params: params)
        case .pipe(let pipe, let sessionID):
            result = try await pipe.request("Runtime.evaluate", params: params, sessionID: sessionID)
        }
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw NSError(domain: "CDP", code: 1, userInfo: [NSLocalizedDescriptionKey: String(describing: exception)])
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    private func sendViaSocket(_ socket: URLSessionWebSocketTask, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": "Runtime.evaluate", "params": params])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))

        while true {
            let payload: Data
            switch try await socket.receive() {
            case .string(let text): payload = Data(text.utf8)
            case .data(let data): payload = data
            @unknown default: throw AssistantError.invalidResponse
            }
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  object["id"] as? Int == id else { continue }
            guard let result = object["result"] as? [String: Any] else { throw AssistantError.invalidResponse }
            return result
        }
    }

    func close() async {
        switch connection {
        case .socket(let socket):
            socket.cancel(with: .normalClosure, reason: nil)
        case .pipe(let pipe, let sessionID):
            _ = try? await pipe.request("Target.detachFromTarget", params: ["sessionId": sessionID])
        }
    }
}

private final class DevToolsDiscovery {
    func targets() async throws -> [DevToolsTarget] {
        let ports = portCandidates().compactMap { url -> Int? in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let firstLine = text.split(whereSeparator: \.isNewline).first,
                  let port = Int(firstLine.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return port
        }
        guard !ports.isEmpty else { throw AssistantError.noDebugPort }
        for port in ports {
            guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { continue }
            let request = URLRequest(url: url, timeoutInterval: 2)
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let pages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            let matches = pages.compactMap { page -> DevToolsTarget? in
                guard (page["type"] as? String) == "page",
                      let rawURL = page["url"] as? String,
                      rawURL.contains("127.0.0.1") || rawURL.contains("localhost"),
                      let rawWebSocket = page["webSocketDebuggerUrl"] as? String,
                      let webSocketURL = URL(string: rawWebSocket) else { return nil }
                return .socket(webSocketURL)
            }
            if !matches.isEmpty { return matches }
        }
        throw AssistantError.noTarget
    }

    private func portCandidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent("Library/Application Support/Antigravity/DevToolsActivePort"),
            home.appendingPathComponent("Library/Application Support/Google/Antigravity/DevToolsActivePort"),
            home.appendingPathComponent(".antigravity/DevToolsActivePort")
        ]
        return paths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

@MainActor
private final class AppModel: ObservableObject {
    @Published var status = "启动并汉化"
    @Published var detail = ""
    @Published var isLocalized = false
    @Published var isBusy = false
    @Published var autoUpdate: Bool
    @Published var launchAtLogin: Bool
    @Published var seamlessLaunch: Bool
    @Published var silentMode: Bool
    @Published var antigravityVersion = "未检测"
    @Published var unknownCount = 0

    var onSilentModeChanged: ((Bool) -> Void)?

    private var translationPack: [String: String] = [:]
    private var unknownStrings = Set<String>()
    private var monitorTask: Task<Void, Never>?
    private let discovery = DevToolsDiscovery()
    private var privateDevTools: PrivateDevTools?
    private var localizationPaused = false
    private var relaunchedPIDs = Set<pid_t>()
    private var lastRelaunchAt: Date = .distantPast

    var managesAntigravity: Bool { privateDevTools?.isRunning == true }

    init() {
        autoUpdate = UserDefaults.standard.object(forKey: "AutoUpdate") as? Bool ?? true
        launchAtLogin = LaunchAtLogin.isEnabled
        seamlessLaunch = UserDefaults.standard.bool(forKey: "SeamlessLaunch")
        silentMode = UserDefaults.standard.bool(forKey: "SilentMode")
        translationPack = Self.loadTranslationPack()
        antigravityVersion = detectAntigravityVersion()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, (self.autoUpdate || self.seamlessLaunch), !self.isBusy, !self.localizationPaused else { continue }
                await self.applyLocalization(silent: true)
            }
        }
    }

    deinit { monitorTask?.cancel() }

    func applyLocalization(silent: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = "正在连接"
        detail = "正在连接 Antigravity 并应用汉化……"
        do {
            let targets: [DevToolsTarget]
            do {
                targets = try await findTargets(allowLaunch: !silent)
            } catch AssistantError.restartRequired where seamlessLaunch {
                guard await tryColdStartRelayIfNeeded() else { throw AssistantError.restartRequired }
                var relayedTargets: [DevToolsTarget]?
                for _ in 0..<12 {
                    if let found = try? await discovery.targets() {
                        relayedTargets = found
                        break
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard let resolved = relayedTargets else { throw AssistantError.noTarget }
                targets = resolved
            }
            if !silent { localizationPaused = false }
            var updateFailed = false
            if autoUpdate {
                do { try await updateTranslationPack() }
                catch { updateFailed = true }
            }
            let script = try makeTranslationScript()
            var found = Set<String>()
            try await visit(targets) { client in
                _ = try await client.evaluate("localStorage.removeItem('__antigravityZhAssistantDisabled'); true")
                guard let outcome = try await client.evaluate(script) as? [String: Any],
                      outcome["ok"] as? Bool == true,
                      outcome["disabled"] == nil else { throw AssistantError.invalidResponse }
                if let values = try await client.evaluate("window.__antigravityZhAssistant?.collectUnknown?.() || []") as? [String] {
                    found.formUnion(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                }
            }
            unknownStrings = found
            unknownCount = found.count
            antigravityVersion = detectAntigravityVersion()
            saveReport()
            isLocalized = true
            status = "汉化已生效"
            let scanDetail = found.isEmpty ? "界面已扫描，当前没有发现待适配的系统词条。" : "发现 \(found.count) 条待适配系统文字。"
            detail = updateFailed ? "\(scanDetail) 自动更新暂不可用，已使用本地词典。" : scanDetail
        } catch {
            isLocalized = false
            status = "启动并汉化"
            detail = error.localizedDescription
        }
    }

    func toggleLocalization() async {
        guard !isBusy else { return }
        if privateDevTools?.isRunning == false { isLocalized = false }
        guard isLocalized else {
            await applyLocalization()
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            try await visit(findTargets(allowLaunch: false)) { client in
                _ = try await client.evaluate("window.__antigravityZhAssistant?.restore?.() || {ok:true}")
            }
            localizationPaused = true
            isLocalized = false
            status = "启动并汉化"
            detail = ""
        } catch { detail = error.localizedDescription }
    }

    private func visit(_ targets: [DevToolsTarget], action: (CDPClient) async throws -> Void) async throws {
        for target in targets {
            let client = try await CDPClient(target: target)
            do {
                try await action(client)
            } catch {
                await client.close()
                throw error
            }
            await client.close()
        }
    }

    private func findTargets(allowLaunch: Bool) async throws -> [DevToolsTarget] {
        if let pipe = privateDevTools, pipe.isRunning {
            return try await targets(from: pipe, waitForPage: allowLaunch)
        }
        privateDevTools = nil

        do {
            return try await discovery.targets()
        } catch {
            let identifier = "com.google.antigravity"
            guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
                throw AssistantError.restartRequired
            }
            guard allowLaunch else { throw error }
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
                  let app = Bundle(url: appURL), app.bundleIdentifier == identifier,
                  let executable = app.executableURL else {
                throw AssistantError.notInstalled
            }
            let pipe = try PrivateDevTools(executable: executable)
            privateDevTools = pipe
            return try await targets(from: pipe, waitForPage: true)
        }
    }

    private func targets(from pipe: PrivateDevTools, waitForPage: Bool) async throws -> [DevToolsTarget] {
        let deadline = DispatchTime.now() + .seconds(waitForPage ? 18 : 0)
        repeat {
            let reply = try await pipe.request("Target.getTargets")
            let pages = (reply["targetInfos"] as? [[String: Any]] ?? []).compactMap { target -> DevToolsTarget? in
                guard target["type"] as? String == "page", target["title"] as? String == "Antigravity",
                      let address = target["url"] as? String, let url = URL(string: address),
                      let host = url.host, ["127.0.0.1", "localhost", "[::1]"].contains(host),
                      let scheme = url.scheme, ["http", "https"].contains(scheme),
                      let id = target["targetId"] as? String else { return nil }
                return .pipe(pipe, targetID: id)
            }
            if !pages.isEmpty { return pages }
            if DispatchTime.now() >= deadline { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        } while pipe.isRunning
        throw AssistantError.noTarget
    }

    func setAutoUpdate(_ value: Bool) {
        autoUpdate = value
        UserDefaults.standard.set(value, forKey: "AutoUpdate")
    }

    func setLaunchAtLogin(_ value: Bool) {
        launchAtLogin = value
        UserDefaults.standard.set(value, forKey: "LaunchAtLogin")
        LaunchAtLogin.setEnabled(value)
    }

    func setSeamlessLaunch(_ value: Bool) {
        seamlessLaunch = value
        UserDefaults.standard.set(value, forKey: "SeamlessLaunch")
    }

    func setSilentMode(_ value: Bool) {
        silentMode = value
        UserDefaults.standard.set(value, forKey: "SilentMode")
        detail = value
            ? "已开启静默运行：关闭窗口后隐藏 Dock 图标并在后台运行，重新打开程序或点击顶部菜单栏图标可再次显示窗口。"
            : "已关闭静默运行：已恢复程序坞（Dock）图标与常规窗口模式。"
        onSilentModeChanged?(value)
    }

    private func tryColdStartRelayIfNeeded() async -> Bool {
        guard seamlessLaunch, privateDevTools == nil else { return false }
        guard Date().timeIntervalSince(lastRelaunchAt) >= 60 else { return false }
        let identifier = "com.google.antigravity"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        let now = Date()
        guard let candidate = running.first(where: { app in
            guard !relaunchedPIDs.contains(app.processIdentifier),
                  let launched = app.launchDate else { return false }
            let uptime = now.timeIntervalSince(launched)
            return uptime >= 2.0 && uptime <= 12.0
        }) else {
            return false
        }
        guard let appURL = candidate.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return false
        }

        relaunchedPIDs.insert(candidate.processIdentifier)
        lastRelaunchAt = now
        _ = candidate.terminate()

        let deadline = Date().addingTimeInterval(3.0)
        while !candidate.isTerminated && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard candidate.isTerminated else { return false }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", appURL.path, "--args", "--remote-debugging-port=0"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return true
    }

    private func updateTranslationPack() async throws {
        let (manifestData, _) = try await URLSession.shared.data(from: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let version = manifest["version"] as? String,
              let packString = manifest["packUrl"] as? String,
              let url = URL(string: packString) else { return }
        let bundledVersion = Self.bundledTranslationPackVersion()
        guard Self.comparePackVersions(version, bundledVersion) == .orderedDescending else { return }
        if UserDefaults.standard.string(forKey: "TranslationPackVersion") == version { return }
        let (packData, _) = try await URLSession.shared.data(from: url)
        guard let pack = try JSONSerialization.jsonObject(with: packData) as? [String: String], !pack.isEmpty else { return }
        translationPack = Self.addingMacOSOverrides(to: pack)
        try packData.write(to: Self.dataDirectory().appendingPathComponent("translation-pack.json"), options: .atomic)
        UserDefaults.standard.set(version, forKey: "TranslationPackVersion")
    }

    func updateTranslationPackManually() async {
        guard !isBusy else { return }
        isBusy = true
        detail = "正在检查词典..."
        do {
            let (manifestData, _) = try await URLSession.shared.data(from: manifestURL)
            guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  let version = manifest["version"] as? String,
                  let packString = manifest["packUrl"] as? String,
                  let url = URL(string: packString) else {
                detail = "无法解析云端词典清单。"
                isBusy = false
                return
            }
            if let minApp = manifest["minimumAssistantVersion"] as? String,
               Self.comparePackVersions(appVersion, minApp) == .orderedAscending {
                detail = "云端词典需要主程序 v\(minApp)+，请前往 GitHub 下载主程序更新。"
                isBusy = false
                return
            }
            let bundledVersion = Self.bundledTranslationPackVersion()
            let cachedVersion = UserDefaults.standard.string(forKey: "TranslationPackVersion") ?? ""
            let effectiveLocal = Self.comparePackVersions(cachedVersion, bundledVersion) == .orderedDescending ? cachedVersion : bundledVersion
            if Self.comparePackVersions(version, effectiveLocal) != .orderedDescending {
                detail = "当前词典已是最新版本（\(effectiveLocal)）。"
                isBusy = false
                return
            }
            detail = "正在下载词典..."
            let (packData, _) = try await URLSession.shared.data(from: url)
            guard let pack = try JSONSerialization.jsonObject(with: packData) as? [String: String], !pack.isEmpty else {
                detail = "下载的词典内容为空。"
                isBusy = false
                return
            }
            translationPack = Self.addingMacOSOverrides(to: pack)
            try packData.write(to: Self.dataDirectory().appendingPathComponent("translation-pack.json"), options: .atomic)
            UserDefaults.standard.set(version, forKey: "TranslationPackVersion")
            if isLocalized {
                isBusy = false
                await applyLocalization(silent: true)
                detail = "词典已更新至 \(version)，并已重新应用。"
                return
            }
            detail = "词典已更新至 \(version)。"
        } catch {
            detail = "检查或下载词典失败，请检查网络连接。"
        }
        isBusy = false
    }

    private func makeTranslationScript() throws -> String {
        guard let url = Self.resourceURL("translator", ext: "js") else { throw AssistantError.invalidResponse }
        var script = try String(contentsOf: url, encoding: .utf8)
        let json = try JSONSerialization.data(withJSONObject: translationPack)
        let encoded = String(decoding: json, as: UTF8.self)
        script = script.replacingOccurrences(of: "__AUTO_ADAPT__", with: autoUpdate ? "true" : "false")
        script = script.replacingOccurrences(of: "__EXTRA_TRANSLATIONS__", with: encoded)
        return script
    }

    private func saveReport() {
        let report: [String: Any] = [
            "assistantVersion": appVersion,
            "antigravityVersion": antigravityVersion,
            "scannedAt": ISO8601DateFormatter().string(from: Date()),
            "count": unknownStrings.count,
            "strings": unknownStrings.sorted()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) else { return }
        try? data.write(to: Self.dataDirectory().appendingPathComponent("待适配词条.json"), options: .atomic)
    }

    private func detectAntigravityVersion() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Antigravity.app"),
            URL(fileURLWithPath: "/Applications/Antigravity IDE.app"),
            home.appendingPathComponent("Applications/Antigravity.app"),
            home.appendingPathComponent("Applications/Antigravity IDE.app")
        ]
        for appURL in candidates {
            if let bundle = Bundle(url: appURL),
               let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               !value.isEmpty { return value }
        }
        return "未安装"
    }

    private static func dataDirectory() -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Antigravity 中文助手")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func resourceURL(_ name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let repositoryRoot = cwd.lastPathComponent == "macOS" ? cwd.deletingLastPathComponent() : cwd
        let candidates = [
            cwd.appendingPathComponent("Resources/\(name).\(ext)"),
            cwd.appendingPathComponent("macOS/Resources/\(name).\(ext)"),
            cwd.appendingPathComponent("src/\(name).\(ext)"),
            cwd.appendingPathComponent("translation/\(name).\(ext)"),
            repositoryRoot.appendingPathComponent("macOS/Resources/\(name).\(ext)"),
            repositoryRoot.appendingPathComponent("src/\(name).\(ext)"),
            repositoryRoot.appendingPathComponent("translation/\(name).\(ext)")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func loadJSON<T: Decodable>(named name: String, ext: String) -> T? {
        guard let url = resourceURL(name, ext: ext), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func loadTranslationPack() -> [String: String] {
        let bundled = addingMacOSOverrides(to: loadJSON(named: "translation-pack", ext: "json") ?? [:])
        let bundledVersion = bundledTranslationPackVersion()
        let cachedVersion = UserDefaults.standard.string(forKey: "TranslationPackVersion") ?? ""
        let cachedURL = dataDirectory().appendingPathComponent("translation-pack.json")
        if comparePackVersions(cachedVersion, bundledVersion) == .orderedDescending,
           let data = try? Data(contentsOf: cachedURL),
           let cached = try? JSONDecoder().decode([String: String].self, from: data),
           !cached.isEmpty { return addingMacOSOverrides(to: cached) }
        return bundled
    }

    private static func bundledTranslationPackVersion() -> String {
        let manifest: [String: String] = loadJSON(named: "translation-manifest", ext: "json") ?? [:]
        return manifest["version"] ?? ""
    }

    private static func comparePackVersions(_ left: String, _ right: String) -> ComparisonResult {
        left.compare(right, options: [.numeric, .caseInsensitive])
    }

    private static func addingMacOSOverrides(to pack: [String: String]) -> [String: String] {
        var result = pack
        let overrides = [
            "Configures how the agent tries to access files outside of its working folders.": "配置智能体尝试访问工作文件夹以外文件的方式。",
            "Controls whether terminal commands require your approval before running.": "控制终端命令在运行前是否需要你的批准。",
            "Enable Sandbox Mode (Preview)": "启用沙盒模式（预览）",
            "Guidelines for interacting with GitHub and request permissions from the user when commands fail due to restrictions in the agent environment.": "用于与 GitHub 交互的指南；当命令因智能体环境限制而失败时，请向用户请求权限。",
            "Install IDE": "安装 IDE",
            "No MCP servers installed": "未安装 MCP 服务器",
            "Outside of folders file access policy": "工作文件夹外的文件访问策略",
            "Proceed in Sandbox": "在沙盒中继续",
            "Restricts agent tools to a secure, isolated local sandbox.": "将智能体工具限制在安全、隔离的本地沙盒中。",
            "Terminal Command Auto Execution": "终端命令自动执行",
            "There was an unexpected issue setting up your account.": "设置账号时出现意外问题。",
            "Continue with different account": "使用其他账号继续",
            "Having trouble? Let us know": "遇到问题？请告诉我们",
            "There are no customizations enabled.": "当前未启用任何自定义项。",
            "Use Add MCP to browse the store, or add a custom server via the MCP config.": "使用“添加 MCP”浏览商店，或通过 MCP 配置添加自定义服务器。"
        ]
        for (english, chinese) in overrides { result[english] = chinese }
        return result
    }
}

private enum LaunchAtLogin {
    static let label = "com.cxartlab.antigravity-zh-assistant"

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func setEnabled(_ enabled: Bool) {
        let url = agentURL
        if enabled {
            guard let executable = Bundle.main.executablePath else { return }
            let plist: [String: Any] = ["Label": label, "ProgramArguments": [executable], "RunAtLoad": true, "ProcessType": "Interactive"]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: url, atomically: true)
            runLaunchctl(["bootstrap", "gui/\(getuid())", url.path])
        } else {
            runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        do {
            try task.run()
            task.waitUntilExit()
        } catch { }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let onWindowReady: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        let size = NSSize(width: 500, height: 550)
        if window.contentView?.frame.size != size || window.styleMask.contains(.resizable) {
            window.setContentSize(size)
            window.minSize = size
            window.maxSize = size
            window.styleMask.remove(.resizable)
            window.center()
        }
        onWindowReady(window)
    }
}

private struct ContentView: View {
    @ObservedObject var model: AppModel
    let onWindowReady: (NSWindow) -> Void

    var body: some View {
        ZStack {
            Color(red: 0.93, green: 0.94, blue: 0.96).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer().frame(height: 76)
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color.cyan.opacity(0.25), .clear], center: .center, startRadius: 0, endRadius: 72))
                        .frame(width: 148, height: 158)
                        .offset(x: -32, y: -8)
                    Circle()
                        .fill(RadialGradient(colors: [Color.yellow.opacity(0.20), .clear], center: .center, startRadius: 0, endRadius: 72))
                        .frame(width: 148, height: 148)
                        .offset(x: 24, y: -22)
                    Circle()
                        .fill(RadialGradient(colors: [Color.red.opacity(0.17), .clear], center: .center, startRadius: 0, endRadius: 68))
                        .frame(width: 134, height: 144)
                        .offset(x: 54, y: -4)
                    Circle()
                        .fill(RadialGradient(colors: [Color.indigo.opacity(0.18), .clear], center: .center, startRadius: 0, endRadius: 74))
                        .frame(width: 151, height: 150)
                        .offset(x: 9, y: 37)
                    Image(nsImage: assistantIconImage())
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                }
                .frame(width: 64, height: 64)
                Text("欢迎使用 Antigravity")
                    .font(.system(size: 30, weight: .regular, design: .rounded))
                    .foregroundColor(Color(red: 0.30, green: 0.31, blue: 0.42))
                    .padding(.top, 26)
                VStack(spacing: 0) {
                    Text("汉化助手 v\(appVersion)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(red: 0.30, green: 0.31, blue: 0.42))
                        .padding(.top, 20)
                    Button { Task { await model.toggleLocalization() } } label: {
                        Text(model.isLocalized ? "✓  汉化已生效" : model.status)
                            .font(.system(size: 18, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .tint(Color(red: 0.52, green: 0.18, blue: 0.93))
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    VStack(spacing: 10) {
                        HStack(spacing: 20) {
                            Toggle("自动更新", isOn: Binding(get: { model.autoUpdate }, set: model.setAutoUpdate))
                                .frame(width: 96, alignment: .leading)
                            Toggle("开机启动", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                                .frame(width: 96, alignment: .leading)
                        }
                        HStack(spacing: 20) {
                            Toggle("无感启动", isOn: Binding(get: { model.seamlessLaunch }, set: model.setSeamlessLaunch))
                                .frame(width: 96, alignment: .leading)
                                .help("冷启动官方 Antigravity 时自动接力开启调试接口并汉化，不中断已运行超过 12 秒的会话。")
                            Toggle("静默运行", isOn: Binding(get: { model.silentMode }, set: model.setSilentMode))
                                .frame(width: 96, alignment: .leading)
                                .help("开启后隐藏程序坞（Dock）图标，启动或关闭窗口时转为后台静默运行（仅保留顶部菜单栏图标）。想再次显示窗口，重新打开本程序或点击顶部菜单栏图标即可。")
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.30, green: 0.31, blue: 0.42))
                    .padding(.top, 16)
                }
                .frame(width: 344, height: 194)
                .background(Color(red: 0.925, green: 0.937, blue: 0.949))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.24)))
                .padding(.top, 36)
                Text("Antigravity \(model.antigravityVersion)  ·  待适配 \(model.unknownCount)")
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.40, green: 0.42, blue: 0.52))
                    .padding(.top, 16)
                Button("更新词典") { Task { await model.updateTranslationPackManually() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.53, green: 0.22, blue: 0.94))
                    .disabled(model.isBusy)
                    .padding(.top, 6)
                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.40, green: 0.42, blue: 0.52))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                }
                Spacer()
            }
        }
        .frame(width: 500, height: 550)
        .background(WindowConfigurator(onWindowReady: onWindowReady))
    }
}

@MainActor
private final class AssistantAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let model = AppModel()
    private weak var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var didHideInitialWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onSilentModeChanged = { [weak self] enabled in
            self?.applySilentMode(enabled)
        }
        applySilentMode(model.silentMode)
    }

    func attachWindow(_ window: NSWindow) {
        mainWindow = window
        window.delegate = self
        if model.silentMode && !didHideInitialWindow {
            didHideInitialWindow = true
            window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func applySilentMode(_ enabled: Bool) {
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        if enabled {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                if let button = item.button {
                    let icon = (assistantIconImage().copy() as? NSImage) ?? assistantIconImage()
                    icon.size = NSSize(width: 18, height: 18)
                    button.image = icon
                    button.toolTip = appName
                }
                let menu = NSMenu()
                let openItem = NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "")
                openItem.target = self
                menu.addItem(openItem)

                let toggleItem = NSMenuItem(title: "切换汉化 / 恢复英文", action: #selector(toggleLocalizationFromMenu), keyEquivalent: "")
                toggleItem.target = self
                menu.addItem(toggleItem)

                menu.addItem(NSMenuItem.separator())

                let quitItem = NSMenuItem(title: "退出助手", action: #selector(quitFromMenu), keyEquivalent: "q")
                quitItem.target = self
                menu.addItem(quitItem)

                item.menu = menu
                statusItem = item
            }
        } else if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }
    }

    @objc func showMainWindow() {
        guard let window = mainWindow ?? NSApp.windows.first else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLocalizationFromMenu() {
        Task { await model.toggleLocalization() }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.silentMode {
            sender.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.silentMode
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.managesAntigravity else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "退出时也会关闭 Antigravity"
        alert.informativeText = "请保存 Antigravity 中的工作后再退出。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
@MainActor
struct AntigravityZhAssistantMacApp: App {
    @NSApplicationDelegateAdaptor(AssistantAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: delegate.model, onWindowReady: { window in
                delegate.attachWindow(window)
            })
        }
        .windowStyle(.hiddenTitleBar)
    }
}
