// DiscordActivity: shows the frontmost macOS app (and briefly what you do in it)
// as Discord Rich Presence, through Discord's local IPC socket.

import AppKit
import ApplicationServices
import ServiceManagement

// MARK: - Config (~/.config/discord-activity/config.json)

struct Config: Codable {
    var clientId = ""
    var hiddenApps: [String] = []   // extra bundle ids that must never be shown
    var idleMinutes = 5             // clear the status after this long without input
    var activityType = 3            // verb Discord puts before the app: 0 playing, 2 listening, 3 watching, 5 competing
    var icons: [String: String] = [:]   // bundle id -> image URL, overrides the automatic icon

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/discord-activity/config.json")

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId) ?? ""
        hiddenApps = try c.decodeIfPresent([String].self, forKey: .hiddenApps) ?? []
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? 5
        activityType = try c.decodeIfPresent(Int.self, forKey: .activityType) ?? 3
        icons = try c.decodeIfPresent([String: String].self, forKey: .icons) ?? [:]
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: Config.url, options: .atomic)
    }
}

// MARK: - What to show for each app

struct Presence: Equatable {
    var name: String      // app name: the title of the card and the member-list status
    var details: String?  // what you are doing, first line
    var state: String?    // extra context, second line
}

/// Apps that never reach Discord, whatever the config says.
let alwaysHidden: Set<String> = [
    "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.keychainaccess",
    "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7",
    "com.bitwarden.desktop", "com.lastpass.LastPass",
]

let chromiumBrowsers: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
    "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
]
let safariBrowsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
let otherBrowsers: Set<String> = ["org.mozilla.firefox", "app.zen-browser.zen", "company.thebrowser.dia"]
/// Always shown as "listening", whatever verb is configured.
let musicApps: Set<String> = ["com.spotify.client", "com.apple.Music"]

/// Apps whose process name is not what people call them.
let displayNames: [String: String] = [
    "com.microsoft.VSCode": "Visual Studio Code",
    "com.microsoft.VSCodeInsiders": "Visual Studio Code Insiders",
    "com.tinyspeck.slackmacgap": "Slack",
]

private func truncated(_ text: String, _ limit: Int = 120) -> String {
    text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
}

/// "main.swift — proyecto" style titles: file and project separated by an em dash.
private func editing(_ title: String?, fileFirst: Bool = true) -> (String, String?) {
    guard var title else { return ("Programando", nil) }
    if title.hasPrefix("● ") { title.removeFirst(2) }
    let parts = title.components(separatedBy: " — ")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard let first = parts.first else { return ("Programando", nil) }
    if parts.count == 1 { return ("En \(first)", nil) }
    let file = fileFirst ? first : parts[parts.count - 1]
    let project = fileFirst ? parts[1] : first
    return ("Editando \(file)", "en \(project)")
}

private func with(_ verb: String, _ title: String?, fallback: String) -> String {
    guard let title else { return fallback }
    return "\(verb) \(title)"
}

/// Maps an app (and its focused window title, when readable) to what Discord shows.
/// Chat, mail and unknown apps never expose their window title.
func describe(bundleId: String, name: String, title: String?, host: String? = nil) -> Presence {
    var details: String?
    var state: String?
    switch bundleId {
    case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
         "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf":
        (details, state) = editing(title)
    case "com.apple.dt.Xcode", "dev.zed.Zed":
        (details, state) = editing(title, fileFirst: false)
    case _ where bundleId.hasPrefix("com.jetbrains.") || bundleId.hasPrefix("com.sublimetext."):
        details = "Programando"
    case "com.google.android.studio":
        details = "Programando"

    case "com.microsoft.Word", "com.apple.iWork.Pages":
        details = with("Editando", title, fallback: "Escribiendo un documento")
    case "com.microsoft.Excel", "com.apple.iWork.Numbers":
        details = with("Editando", title, fallback: "En una hoja de cálculo")
    case "com.microsoft.Powerpoint", "com.apple.iWork.Keynote":
        details = with("Editando", title, fallback: "Preparando una presentación")
    case "com.apple.Preview", "com.adobe.Reader", "com.adobe.Acrobat.Pro":
        details = with("Leyendo", title, fallback: "Leyendo un documento")
    case "com.figma.Desktop":
        details = with("Diseñando", title, fallback: "Diseñando")
    case "org.blenderfoundation.blender":
        details = "Modelando en 3D"

    case _ where chromiumBrowsers.contains(bundleId) || safariBrowsers.contains(bundleId)
        || otherBrowsers.contains(bundleId):
        details = host.map { "En \($0)" } ?? "Navegando"

    case "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
         "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm":
        details = "En la terminal"

    case "com.anthropic.claudefordesktop":
        details = "Trabajando con Claude"
    case "com.openai.chat":
        details = "Conversando con ChatGPT"

    case "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
         "com.apple.MobileSMS", "com.microsoft.teams2", "org.whispersystems.signal-desktop":
        details = "Chateando"
    case "us.zoom.xos", "com.apple.FaceTime":
        details = "En una llamada"
    case "com.apple.mail", "com.microsoft.Outlook":
        details = "Revisando el correo"

    case "com.apple.finder":
        details = "Explorando archivos"
    case "notion.id", "md.obsidian", "com.apple.Notes":
        details = "Tomando notas"
    default:
        break   // the app name alone says enough (Discord, Spotify, Settings, unknown apps…)
    }
    return Presence(name: truncated(displayNames[bundleId] ?? name),
                    details: details.map { truncated($0) },
                    state: state.map { truncated($0) })
}

// MARK: - App icons

/// Discord only shows images it can download, so the local .icns is no use: icons come
/// from a public icon set for well-known apps, and from the App Store for the rest.
final class IconStore {
    private static let cdn = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/"
    private static let known: [String: String] = [
        "com.microsoft.VSCode": "vscode", "com.microsoft.VSCodeInsiders": "vscode",
        "com.google.Chrome": "google-chrome", "com.google.Chrome.canary": "google-chrome",
        "com.brave.Browser": "brave", "com.microsoft.edgemac": "microsoft-edge",
        "com.vivaldi.Vivaldi": "vivaldi", "org.mozilla.firefox": "firefox",
        "app.zen-browser.zen": "zen-browser", "com.apple.Safari": "safari",
        "com.anthropic.claudefordesktop": "claude-ai", "com.openai.chat": "chatgpt",
        "com.apple.Terminal": "terminal", "com.googlecode.iterm2": "terminal",
        "dev.warp.Warp-Stable": "terminal", "net.kovidgoyal.kitty": "terminal",
        "com.github.wez.wezterm": "terminal", "com.mitchellh.ghostty": "ghostty",
        "org.alacritty": "alacritty",
        "com.hnc.Discord": "discord", "com.hnc.DiscordPTB": "discord", "com.hnc.DiscordCanary": "discord",
        "com.figma.Desktop": "figma", "notion.id": "notion", "md.obsidian": "obsidian",
        "org.blenderfoundation.blender": "blender", "us.zoom.xos": "zoom",
        "ru.keepcoder.Telegram": "telegram", "org.whispersystems.signal-desktop": "signal",
        "com.microsoft.teams2": "microsoft-teams", "com.apple.Music": "apple-music",
    ]
    private static let file = Config.url.deletingLastPathComponent().appendingPathComponent("icons.json")

    private var looked: [String: String]            // App Store answers; "" means "not there"
    private var pending = Set<String>()
    private var failedAt: [String: Date] = [:]

    init() {
        let data = try? Data(contentsOf: IconStore.file)
        looked = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// Main thread only. May return nil now and a URL on a later call, once the lookup ends.
    func url(for bundleId: String, overrides: [String: String]) -> String? {
        if let custom = overrides[bundleId] { return custom }
        if let name = IconStore.known[bundleId] { return IconStore.cdn + name + ".png" }
        if let found = looked[bundleId] {
            if !found.isEmpty { return found }
            return bundleId.hasPrefix("com.apple.") ? IconStore.cdn + "apple.png" : nil
        }
        lookUp(bundleId)
        return nil
    }

    /// Asks the App Store for the icon of this bundle id, once; the answer is kept on disk.
    private func lookUp(_ bundleId: String) {
        if pending.contains(bundleId) { return }
        if let failed = failedAt[bundleId], Date().timeIntervalSince(failed) < 600 { return }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "bundleId", value: bundleId)]
        guard let url = components.url else { return }
        pending.insert(bundleId)
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            var answer: String?
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let results = json["results"] as? [[String: Any]] {
                answer = (results.first?["artworkUrl512"] as? String) ?? ""
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(bundleId)
                guard let answer else { self.failedAt[bundleId] = Date(); return }
                self.looked[bundleId] = answer
                try? JSONEncoder().encode(self.looked).write(to: IconStore.file, options: .atomic)
            }
        }.resume()
    }
}

// MARK: - Reading the frontmost app

/// Title of the focused window. Needs the Accessibility permission; nil without it.
func focusedWindowTitle(pid: pid_t) -> String? {
    guard AXIsProcessTrusted() else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
          let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success,
          let title = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !title.isEmpty else { return nil }
    return title
}

private var browserScripts: [String: NSAppleScript] = [:]

/// Domain of the active tab (never the full URL or the page title). nil for private
/// windows, internal pages, or when the Automation permission was denied.
func browserHost(bundleId: String) -> String? {
    let source: String
    if safariBrowsers.contains(bundleId) {
        source = """
        tell application id "\(bundleId)"
            if (count of documents) is 0 then return ""
            return URL of front document
        end tell
        """
    } else if chromiumBrowsers.contains(bundleId) {
        source = """
        tell application id "\(bundleId)"
            if (count of windows) is 0 then return ""
            set windowMode to "normal"
            try
                set windowMode to mode of front window
            end try
            if windowMode is "incognito" then return ""
            return URL of active tab of front window
        end tell
        """
    } else {
        return nil
    }
    if browserScripts[bundleId] == nil { browserScripts[bundleId] = NSAppleScript(source: source) }
    var error: NSDictionary?
    guard let url = browserScripts[bundleId]?.executeAndReturnError(&error).stringValue,
          let parts = URLComponents(string: url),
          let scheme = parts.scheme, scheme.hasPrefix("http"),
          var host = parts.host, !host.isEmpty else { return nil }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host
}

func secondsIdle() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

/// What should be on Discord right now; nil means "show nothing".
func currentPresence(config: Config) -> (bundleId: String, presence: Presence)? {
    guard secondsIdle() < Double(config.idleMinutes * 60),
          let app = NSWorkspace.shared.frontmostApplication,
          let bundleId = app.bundleIdentifier,
          bundleId != Bundle.main.bundleIdentifier,
          !alwaysHidden.contains(bundleId), !config.hiddenApps.contains(bundleId) else { return nil }
    let name = app.localizedName ?? bundleId
    let title = focusedWindowTitle(pid: app.processIdentifier)
    let host = browserHost(bundleId: bundleId)
    return (bundleId, describe(bundleId: bundleId, name: name, title: title, host: host))
}

// MARK: - Discord local IPC

final class DiscordIPC {
    private var fd: Int32 = -1
    var isConnected: Bool { fd >= 0 }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// Connects and performs the handshake. Returns an error text, or nil on success.
    func connect(clientId: String) -> String? {
        close()
        for index in 0..<10 {
            let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("discord-ipc-\(index)")
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            guard sock >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(sock); continue }
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { Darwin.close(sock); continue }
            fd = sock
            guard write(op: 0, ["v": 1, "client_id": clientId]), let reply = readFrame(timeoutMs: 3000) else {
                close()
                continue
            }
            if reply.op == 1, reply.json["evt"] as? String == "READY" { return nil }
            close()
            return (reply.json["message"] as? String) ?? "Discord rechazó la conexión"
        }
        return "Discord no está abierto"
    }

    /// Sets (or clears, with nil) the activity. Returns an error text, or nil on success.
    func setActivity(_ activity: [String: Any]?) -> String? {
        let nonce = UUID().uuidString
        let args: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "activity": activity ?? NSNull(),
        ]
        guard write(op: 1, ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce]) else {
            return "Se perdió la conexión con Discord"
        }
        // Read until our reply shows up; stale replies from earlier commands are skipped.
        for _ in 0..<5 {
            guard let reply = readFrame(timeoutMs: 1500) else { break }
            guard reply.json["nonce"] as? String == nonce else { continue }
            if reply.json["evt"] as? String == "ERROR" {
                let data = reply.json["data"] as? [String: Any]
                return (data?["message"] as? String) ?? "Discord devolvió un error"
            }
            return nil
        }
        return isConnected ? nil : "Se perdió la conexión con Discord"
    }

    private func write(op: Int32, _ payload: [String: Any]) -> Bool {
        guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var frame = Data()
        withUnsafeBytes(of: op.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(body.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        let sent = frame.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        if sent != frame.count { close(); return false }
        return true
    }

    private func readFrame(timeoutMs: Int32) -> (op: Int32, json: [String: Any])? {
        while true {
            guard let header = readExact(8, timeoutMs: timeoutMs) else { return nil }
            let op = Int32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
            let length = Int32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
            guard length >= 0, length < 4_000_000, let body = readExact(Int(length), timeoutMs: timeoutMs) else {
                close()
                return nil
            }
            let json = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
            switch op {
            case 3: _ = write(op: 4, json)      // ping: answer and keep reading
            case 2: close(); return (op, json)  // Discord closed the connection
            default: return (op, json)
            }
        }
    }

    private func readExact(_ count: Int, timeoutMs: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < count {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard fd >= 0, poll(&descriptor, 1, timeoutMs) > 0 else {
                if !data.isEmpty { close() }    // half a frame: the stream is unusable
                return nil
            }
            let received = recv(fd, &buffer, min(buffer.count, count - data.count), 0)
            guard received > 0 else { close(); return nil }
            data.append(buffer, count: received)
        }
        return data
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private let icons = IconStore()
    private let ipc = DiscordIPC()
    private let ipcQueue = DispatchQueue(label: "discord-ipc")

    // Main thread state
    private var statusItem: NSStatusItem!
    private let infoItem = NSMenuItem(title: "Iniciando…", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pausar", action: #selector(togglePause), keyEquivalent: "p")
    private let loginItem = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "Dar permiso de Accesibilidad…", action: #selector(askAccessibility), keyEquivalent: "")
    private let verbItem = NSMenuItem(title: "Verbo en Discord", action: nil, keyEquivalent: "")
    private var paused = false
    private var currentBundleId: String?
    private var startedAt = Date()

    // ipcQueue state
    private var lastSent: [String: String]? = [:]   // [:] never matches, so the first tick always sends

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(.separator())
        // Discord always puts one of these verbs before the app name; it cannot be removed.
        let verbs = NSMenu()
        for (title, type) in [("Viendo", 3), ("Jugando", 0), ("Escuchando", 2), ("Compitiendo en", 5)] {
            let item = NSMenuItem(title: title, action: #selector(chooseVerb(_:)), keyEquivalent: "")
            item.target = self
            item.tag = type
            verbs.addItem(item)
        }
        verbItem.submenu = verbs
        for item in [pauseItem, loginItem, verbItem, accessItem,
                     NSMenuItem(title: "Client ID de Discord…", action: #selector(askClientId), keyEquivalent: "")] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateIcon()

        if !AXIsProcessTrusted() { askAccessibility() }
        if config.clientId.isEmpty { askClientId() }

        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 1
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcQueue.sync {
            if ipc.isConnected { _ = ipc.setActivity(nil) }
            ipc.close()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.state = paused ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        accessItem.isHidden = AXIsProcessTrusted()
        verbItem.submenu?.items.forEach { $0.state = $0.tag == config.activityType ? .on : .off }
    }

    private func updateIcon() {
        let symbol = paused ? "pause.circle" : "dot.radiowaves.left.and.right"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Discord Activity")
    }

    // Runs on the main thread every 5 s: well under Discord's limit of 5 updates per 20 s.
    private func tick() {
        guard !config.clientId.isEmpty else { infoItem.title = "Falta el Client ID de Discord"; return }
        var activity: [String: String]?
        var summary = paused ? "En pausa" : "Nada que mostrar (inactivo u oculto)"
        if !paused, let (bundleId, presence) = currentPresence(config: config) {
            if bundleId != currentBundleId { startedAt = Date() }   // timer restarts per app, not per file
            currentBundleId = bundleId
            activity = [
                "name": presence.name,
                "type": String(musicApps.contains(bundleId) ? 2 : config.activityType),
                "start": String(Int(startedAt.timeIntervalSince1970 * 1000)),
            ]
            activity?["details"] = presence.details
            activity?["state"] = presence.state
            activity?["icon"] = icons.url(for: bundleId, overrides: config.icons)
            summary = [presence.name, presence.details, presence.state].compactMap { $0 }.joined(separator: " — ")
        } else {
            currentBundleId = nil
        }
        let clientId = config.clientId
        ipcQueue.async { [weak self] in
            guard let self else { return }
            let problem = self.push(activity, clientId: clientId)
            DispatchQueue.main.async { self.infoItem.title = problem ?? summary }
        }
    }

    /// Runs on ipcQueue. Sends only when something changed. Returns an error text, or nil.
    private func push(_ activity: [String: String]?, clientId: String) -> String? {
        if !ipc.isConnected {
            if let problem = ipc.connect(clientId: clientId) { return problem }
            lastSent = [:]
        }
        guard activity != lastSent else { return nil }
        let problem = ipc.setActivity(activity.map(payload))
        if problem == nil { lastSent = activity }
        return problem
    }

    private func payload(_ activity: [String: String]) -> [String: Any] {
        let name = activity["name"] ?? ""
        var result: [String: Any] = [
            "type": Int(activity["type"] ?? "") ?? 3,
            "name": name,   // replaces the Discord application's own name as the card title
            "timestamps": ["start": Int(activity["start"] ?? "") ?? 0],
        ]
        if let details = activity["details"] { result["details"] = details }
        if let state = activity["state"] { result["state"] = state }
        if let icon = activity["icon"] { result["assets"] = ["large_image": icon, "large_text": name] }
        return result
    }

    @objc private func togglePause() {
        paused.toggle()
        updateIcon()
        tick()
    }

    @objc private func chooseVerb(_ sender: NSMenuItem) {
        config.activityType = sender.tag
        config.save()
        tick()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func askAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func askClientId() {
        let alert = NSAlert()
        alert.messageText = "Client ID de Discord"
        alert.informativeText = "Crea una aplicación en discord.com/developers/applications y pega aquí su Application ID."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = config.clientId
        field.placeholderString = "123456789012345678"
        alert.accessoryView = field
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return }
        config.clientId = value
        config.save()
        ipcQueue.async { [weak self] in self?.ipc.close() }   // reconnect with the new id
        tick()
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
if arguments.contains("--samples") {
    // Prints what would be shown for a few known window titles; touches nothing else.
    let samples: [(String, String, String?, String?)] = [
        ("com.microsoft.VSCode", "Code", "● main.swift — discord-activity", nil),
        ("com.microsoft.VSCode", "Code", "discord-activity", nil),
        ("com.microsoft.VSCode", "Code", nil, nil),
        ("com.apple.dt.Xcode", "Xcode", "MiApp — ContentView.swift", nil),
        ("com.microsoft.Word", "Microsoft Word", "Informe final.docx", nil),
        ("com.microsoft.Word", "Microsoft Word", nil, nil),
        ("com.google.Chrome", "Google Chrome", "Bandeja de entrada - Gmail", "mail.google.com"),
        ("com.google.Chrome", "Google Chrome", "Pestaña privada", nil),
        ("com.apple.Terminal", "Terminal", "usuario — zsh — 80×24", nil),
        ("com.anthropic.claudefordesktop", "Claude", "Claude", nil),
        ("com.tinyspeck.slackmacgap", "Slack", "canal-secreto - Empresa - Slack", nil),
        ("net.whatsapp.WhatsApp", "WhatsApp", "Chat con mamá", nil),
        ("com.example.desconocida", "Otra App", "Título privado", nil),
    ]
    for (bundleId, name, title, host) in samples {
        let presence = describe(bundleId: bundleId, name: name, title: title, host: host)
        print("\(bundleId)\t\(title ?? "(sin título)")\t=> \(presence.name) | \(presence.details ?? "-") | \(presence.state ?? "-")")
    }
    exit(0)
}

if let flag = arguments.firstIndex(of: "--ipc-test") {
    // Sends one sample activity for 15 s, to check the Discord connection without the menu bar app.
    let given = arguments.dropFirst(flag + 1).first { $0.allSatisfy(\.isNumber) }
    let clientId = given ?? Config.load().clientId
    let ipc = DiscordIPC()
    if let problem = ipc.connect(clientId: clientId) { print("Conexión falló: \(problem)"); exit(1) }
    let problem = ipc.setActivity([
        "type": 3, "name": "Prueba", "details": "Probando la conexión",
        "timestamps": ["start": Int(Date().timeIntervalSince1970 * 1000)],
    ])
    print(problem.map { "Discord rechazó la actividad: \($0)" } ?? "Actividad enviada; mira tu perfil de Discord")
    if problem == nil, !arguments.contains("--no-wait") { sleep(15) }
    exit(problem == nil ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if arguments.contains("--dry-run") {
    // Prints the live presence a few times without connecting to Discord or showing any UI.
    var remaining = 3
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        let accessibility = AXIsProcessTrusted() ? "sí" : "no"
        if let (bundleId, presence) = currentPresence(config: Config.load()) {
            print("\(bundleId) => \(presence.name) | \(presence.details ?? "-") | \(presence.state ?? "-") [accesibilidad: \(accessibility)]")
        } else {
            print("(nada que mostrar) [accesibilidad: \(accessibility)]")
        }
        remaining -= 1
        if remaining == 0 { exit(0) }
    }
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
