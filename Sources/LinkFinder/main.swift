import Foundation

enum LinkFinderError: Error, CustomStringConvertible {
    case usage(String)
    case notFound(String)
    case notAnApp(String)

    var description: String {
        switch self {
        case .usage(let value), .notFound(let value), .notAnApp(let value):
            return value
        }
    }
}

struct ScanOptions {
    var json = false
    var verify = false
    var limit = 80
    var maxFiles = 2_500
    var maxFileBytes = 2 * 1024 * 1024
    var verifyLimit = 10
    var filter: String?
}

struct ScanReport: Codable {
    let schema: Int
    let app: AppInfo
    let declaredSchemes: [String]
    let associatedDomains: [String]
    let activityTypes: [String]
    let systemSettingsPanes: [SettingsPane]
    let candidates: [DeepLinkCandidate]
    let scan: ScanStats
    var verification: [VerificationResult]?
    let notes: [String]
}

struct AppInfo: Codable {
    let path: String
    let name: String
    let bundleIdentifier: String?
    let executable: String?
    let infoPlist: String?
}

struct SettingsPane: Codable {
    let identifier: String
    let name: String?
    let source: String
}

struct DeepLinkCandidate: Codable, Hashable {
    let url: String
    let confidence: String
    let source: String
    let reason: String
}

struct ScanStats: Codable {
    let filesVisited: Int
    let filesScanned: Int
    let filesSkipped: Int
    let truncated: Bool
}

struct VerificationResult: Codable {
    let url: String
    let ok: Bool
    let status: Int32
    let error: String?
}

struct ScanAccumulator {
    var urlCandidates: [String: DeepLinkCandidate] = [:]
    var bundleIdentifiers: [String: String] = [:]
    var filesVisited = 0
    var filesScanned = 0
    var filesSkipped = 0
    var truncated = false
}

let textExtensions: Set<String> = [
    "entitlements",
    "html",
    "js",
    "json",
    "plist",
    "strings",
    "txt",
    "xml"
]

do {
    let (command, appPath, options) = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    switch command {
    case "scan":
        var report = try scanApp(at: appPath, options: options)
        if options.verify {
            report.verification = verify(candidates: report.candidates, options: options)
        }
        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try encoder.encode(report), encoding: .utf8)!)
        } else {
            printHuman(report, limit: options.limit)
        }
    case "help":
        printHelp()
    default:
        throw LinkFinderError.usage("Unknown command: \(command)")
    }
} catch let error as LinkFinderError {
    FileHandle.standardError.write(Data("linkfinder: \(error.description)\n\n".utf8))
    printHelp(to: .standardError)
    exit(1)
} catch {
    FileHandle.standardError.write(Data("linkfinder: \(error.localizedDescription)\n".utf8))
    exit(1)
}

func parseArguments(_ args: [String]) throws -> (String, String, ScanOptions) {
    guard let first = args.first else {
        return ("help", "", ScanOptions())
    }
    if first == "help" || first == "--help" || first == "-h" {
        return ("help", "", ScanOptions())
    }
    guard first == "scan" else {
        throw LinkFinderError.usage("Expected `scan`.")
    }

    var options = ScanOptions()
    var positionals: [String] = []
    var index = 1
    while index < args.count {
        let arg = args[index]
        if !arg.hasPrefix("--") {
            positionals.append(arg)
            index += 1
            continue
        }

        switch arg {
        case "--json":
            options.json = true
        case "--verify":
            options.verify = true
        case "--limit":
            index += 1
            options.limit = try readInt(args, index, name: "--limit")
        case "--max-files":
            index += 1
            options.maxFiles = try readInt(args, index, name: "--max-files")
        case "--max-file-bytes":
            index += 1
            options.maxFileBytes = try readInt(args, index, name: "--max-file-bytes")
        case "--verify-limit":
            index += 1
            options.verifyLimit = try readInt(args, index, name: "--verify-limit")
        case "--filter":
            index += 1
            guard index < args.count else { throw LinkFinderError.usage("Missing value for --filter.") }
            options.filter = args[index]
        default:
            throw LinkFinderError.usage("Unknown option: \(arg)")
        }
        index += 1
    }

    guard let appPath = positionals.first else {
        throw LinkFinderError.usage("Usage: linkfinder scan <App.app> [--json] [--verify]")
    }
    return ("scan", appPath, options)
}

func readInt(_ args: [String], _ index: Int, name: String) throws -> Int {
    guard index < args.count, let value = Int(args[index]) else {
        throw LinkFinderError.usage("Missing integer value for \(name).")
    }
    return value
}

func scanApp(at inputPath: String, options: ScanOptions) throws -> ScanReport {
    let bundleURL = URL(fileURLWithPath: inputPath).standardizedFileURL
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: bundleURL.path) else {
        throw LinkFinderError.notFound("App not found: \(bundleURL.path)")
    }
    guard bundleURL.pathExtension == "app" else {
        throw LinkFinderError.notAnApp("Expected a .app bundle: \(bundleURL.path)")
    }

    let bundle = Bundle(url: bundleURL)
    let info = bundle?.infoDictionary ?? [:]
    let executable = info["CFBundleExecutable"] as? String
    let executableURL = executable.map { bundleURL.appendingPathComponent("Contents/MacOS/\($0)") }
    let accumulator = scanBundle(bundleURL, executableURL: executableURL, options: options)
    let schemes = declaredSchemes(from: info)
    let panes = discoverSystemSettingsPanes(bundleURL, info: info, accumulator: accumulator)
    var candidates = schemes.map {
        DeepLinkCandidate(
            url: "\($0)://",
            confidence: "declared",
            source: "Contents/Info.plist",
            reason: "The app registers this URL scheme with Launch Services."
        )
    }
    candidates += panes.map {
        DeepLinkCandidate(
            url: "x-apple.systempreferences:\($0.identifier)",
            confidence: "likely",
            source: $0.source,
            reason: "System Settings panes are commonly addressable by extension or preference identifiers."
        )
    }
    candidates += Array(accumulator.urlCandidates.values)
    candidates = ranked(candidates)

    if candidates.count > options.limit {
        candidates = Array(candidates.prefix(options.limit))
    }

    return ScanReport(
        schema: 1,
        app: AppInfo(
            path: bundleURL.path,
            name: bundleURL.lastPathComponent,
            bundleIdentifier: info["CFBundleIdentifier"] as? String,
            executable: executable,
            infoPlist: bundleURL.appendingPathComponent("Contents/Info.plist").path
        ),
        declaredSchemes: schemes,
        associatedDomains: associatedDomains(in: bundleURL),
        activityTypes: info["NSUserActivityTypes"] as? [String] ?? [],
        systemSettingsPanes: panes,
        candidates: candidates,
        scan: ScanStats(
            filesVisited: accumulator.filesVisited,
            filesScanned: accumulator.filesScanned,
            filesSkipped: accumulator.filesSkipped,
            truncated: accumulator.truncated
        ),
        verification: nil,
        notes: [
            "Deep-link discovery is heuristic. Apps can construct private routes at runtime or reject routes that look valid.",
            "Use --verify sparingly: it opens candidate URLs and may launch or change app state."
        ]
    )
}

func declaredSchemes(from info: [String: Any]) -> [String] {
    guard let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
    var schemes = Set<String>()
    for type in urlTypes {
        guard let values = type["CFBundleURLSchemes"] as? [String] else { continue }
        for scheme in values where scheme.range(of: #"^[a-z][a-z0-9+.-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            schemes.insert(scheme)
        }
    }
    return schemes.sorted()
}

func associatedDomains(in bundleURL: URL) -> [String] {
    let paths = [
        bundleURL.appendingPathComponent("Contents/archived-expanded-entitlements.xcent"),
        bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
    ]
    var domains = Set<String>()
    for url in paths {
        guard let plist = readPlist(url) as? [String: Any],
              let values = plist["com.apple.developer.associated-domains"] as? [String] else {
            continue
        }
        domains.formUnion(values)
    }
    return domains.sorted()
}

func scanBundle(_ bundleURL: URL, executableURL: URL?, options: ScanOptions) -> ScanAccumulator {
    var accumulator = ScanAccumulator()
    guard let enumerator = FileManager.default.enumerator(
        at: bundleURL,
        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else {
        return accumulator
    }

    for case let url as URL in enumerator {
        if shouldSkip(url) {
            enumerator.skipDescendants()
            continue
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { continue }

        accumulator.filesVisited += 1
        if accumulator.filesVisited > options.maxFiles {
            accumulator.truncated = true
            break
        }

        if (values?.fileSize ?? 0) > options.maxFileBytes {
            accumulator.filesSkipped += 1
            continue
        }

        guard let text = candidateText(from: url, executableURL: executableURL) else {
            accumulator.filesSkipped += 1
            continue
        }

        accumulator.filesScanned += 1
        collectURLs(in: text, source: relativePath(url, under: bundleURL), accumulator: &accumulator)
        collectBundleIDs(in: text, source: relativePath(url, under: bundleURL), accumulator: &accumulator)
    }

    return accumulator
}

func shouldSkip(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return name == "_CodeSignature" || name == "CodeResources" || name == "Frameworks"
}

func candidateText(from url: URL, executableURL: URL?) -> String? {
    let ext = url.pathExtension.lowercased()
    if executableURL == url || isLikelyBinary(url) {
        return run("/usr/bin/strings", ["-a", "-n", "4", url.path]).output
    }
    guard textExtensions.contains(ext) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
}

func isLikelyBinary(_ url: URL) -> Bool {
    let path = url.path
    let ext = url.pathExtension.lowercased()
    return ext.isEmpty || ext == "dylib" || path.contains("/Contents/MacOS/")
}

func collectURLs(in text: String, source: String, accumulator: inout ScanAccumulator) {
    for value in matches(#"\b[a-z][a-z0-9+.-]{1,40}:(?:(?:\/\/)?[^\s"'`<>)}\]]+|[A-Za-z0-9._~/?#[\]@!$&()*+,;=%-]+)"#, in: text) {
        let url = cleanup(value)
        guard isUsefulURL(url), accumulator.urlCandidates[url] == nil else { continue }
        accumulator.urlCandidates[url] = DeepLinkCandidate(
            url: url,
            confidence: "found",
            source: source,
            reason: "This URL-like string appears in the app bundle."
        )
    }
}

func collectBundleIDs(in text: String, source: String, accumulator: inout ScanAccumulator) {
    for value in matches(#"\b[A-Za-z0-9-]+(?:\.[A-Za-z0-9][A-Za-z0-9_-]+){2,}\b"#, in: text) {
        let identifier = cleanup(value)
        guard isUsefulBundleID(identifier), accumulator.bundleIdentifiers[identifier] == nil else { continue }
        accumulator.bundleIdentifiers[identifier] = source
    }
}

func discoverSystemSettingsPanes(_ bundleURL: URL, info: [String: Any], accumulator: ScanAccumulator) -> [SettingsPane] {
    let bundleID = info["CFBundleIdentifier"] as? String
    let isSystemSettings = bundleID == "com.apple.systempreferences" || bundleURL.lastPathComponent == "System Settings.app"
    guard isSystemSettings else { return [] }

    var panes: [String: SettingsPane] = [:]
    for pluginURL in nestedBundles(under: bundleURL.appendingPathComponent("Contents/PlugIns"), extension: "appex") {
        let plistURL = pluginURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = readPlist(plistURL) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String else {
            continue
        }
        panes[identifier] = SettingsPane(
            identifier: identifier,
            name: plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String,
            source: relativePath(plistURL, under: bundleURL)
        )
    }

    for pluginURL in nestedBundles(under: bundleURL.appendingPathComponent("Contents/Resources"), extension: "prefPane") {
        let plistURL = pluginURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = readPlist(plistURL) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String else {
            continue
        }
        panes[identifier] = SettingsPane(
            identifier: identifier,
            name: plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String,
            source: relativePath(plistURL, under: bundleURL)
        )
    }

    for (identifier, source) in accumulator.bundleIdentifiers where identifier.range(of: #"com\.apple\..*(settings|preference|extension)"#, options: [.regularExpression, .caseInsensitive]) != nil {
        panes[identifier] = SettingsPane(identifier: identifier, name: nil, source: source)
    }

    return panes.values.sorted { $0.identifier < $1.identifier }
}

func nestedBundles(under root: URL, extension targetExtension: String) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
        return []
    }
    var found: [URL] = []
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        if url.pathExtension == targetExtension {
            found.append(url)
            enumerator.skipDescendants()
        }
    }
    return found
}

func verify(candidates: [DeepLinkCandidate], options: ScanOptions) -> [VerificationResult] {
    let filtered = candidates.filter {
        guard let pattern = options.filter else { return true }
        return $0.url.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }.prefix(options.verifyLimit)

    return filtered.map { candidate in
        let result = run("/usr/bin/open", [candidate.url])
        return VerificationResult(
            url: candidate.url,
            ok: result.status == 0,
            status: result.status,
            error: result.error.isEmpty ? nil : result.error
        )
    }
}

func ranked(_ candidates: [DeepLinkCandidate]) -> [DeepLinkCandidate] {
    var byURL: [String: DeepLinkCandidate] = [:]
    for candidate in candidates {
        if let existing = byURL[candidate.url], rank(existing.confidence) >= rank(candidate.confidence) {
            continue
        }
        byURL[candidate.url] = candidate
    }
    return byURL.values.sorted {
        if rank($0.confidence) != rank($1.confidence) {
            return rank($0.confidence) > rank($1.confidence)
        }
        return $0.url < $1.url
    }
}

func rank(_ confidence: String) -> Int {
    switch confidence {
    case "declared": return 3
    case "likely": return 2
    case "found": return 1
    default: return 0
    }
}

func readPlist(_ url: URL) -> Any? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
}

func matches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap {
        Range($0.range, in: text).map { String(text[$0]) }
    }
}

func cleanup(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r.,;:"))
}

func isUsefulURL(_ url: String) -> Bool {
    guard let scheme = url.split(separator: ":").first?.lowercased(), !scheme.isEmpty else { return false }
    if ["file", "data", "javascript", "mailto"].contains(String(scheme)) { return false }
    if url.count > 500 { return false }
    if url.range(of: #"^https?://(www\.)?w3\.org/"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
    return true
}

func isUsefulBundleID(_ identifier: String) -> Bool {
    identifier.count <= 160 && !identifier.hasPrefix(".") && !identifier.contains("..")
}

func relativePath(_ url: URL, under root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return path }
    return String(path.dropFirst(rootPath.count + 1))
}

func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
    let process = Process()
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
        try process.run()
        process.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output, error)
    } catch {
        return (127, "", error.localizedDescription)
    }
}

func printHuman(_ report: ScanReport, limit: Int) {
    print("App: \(report.app.name)")
    print("Path: \(report.app.path)")
    print("Bundle ID: \(report.app.bundleIdentifier ?? "unknown")")
    if let executable = report.app.executable {
        print("Executable: \(executable)")
    }
    print("")

    print("Declared schemes (\(report.declaredSchemes.count))")
    if report.declaredSchemes.isEmpty {
        print("  none")
    } else {
        for scheme in report.declaredSchemes {
            print("  \(scheme)://")
        }
    }
    print("")

    if !report.associatedDomains.isEmpty {
        print("Associated domains")
        for domain in report.associatedDomains {
            print("  \(domain)")
        }
        print("")
    }

    if !report.activityTypes.isEmpty {
        print("NSUserActivity types")
        for activityType in report.activityTypes {
            print("  \(activityType)")
        }
        print("")
    }

    if !report.systemSettingsPanes.isEmpty {
        print("System Settings panes (\(report.systemSettingsPanes.count))")
        for pane in report.systemSettingsPanes.prefix(limit) {
            let label = pane.name.map { " \($0)" } ?? ""
            print("  x-apple.systempreferences:\(pane.identifier)\(label)")
        }
        print("")
    }

    print("Candidates (\(report.candidates.count))")
    if report.candidates.isEmpty {
        print("  none")
    } else {
        for candidate in report.candidates.prefix(limit) {
            print("  [\(candidate.confidence)] \(candidate.url)")
            print("      \(candidate.source)")
        }
    }
    print("")

    print("Scanned \(report.scan.filesScanned) files (\(report.scan.filesSkipped) skipped, \(report.scan.filesVisited) visited)")
    if report.scan.truncated {
        print("Scan stopped at the max file limit. Increase --max-files for a deeper pass.")
    }
    if let verification = report.verification, !verification.isEmpty {
        print("")
        print("Verification")
        for item in verification {
            let status = item.ok ? "ok" : "failed"
            print("  [\(status)] \(item.url)")
            if let error = item.error {
                print("      \(error)")
            }
        }
    }
}

func printHelp(to handle: FileHandle = .standardOutput) {
    let text = """
    linkfinder - best-effort macOS app deep-link discovery

    Usage:
      linkfinder scan <App.app> [--json] [--limit N]
      linkfinder scan <App.app> --verify [--verify-limit N] [--filter REGEX]

    Examples:
      linkfinder scan "/System/Applications/System Settings.app"
      linkfinder scan "/Applications/Obsidian.app" --json
      linkfinder scan "/System/Applications/System Settings.app" --verify --filter General

    Notes:
      Discovery is heuristic. It reads bundle metadata, scans strings/resources, and derives
      System Settings pane URLs where possible. --verify calls /usr/bin/open on candidates.
    """
    handle.write(Data((text + "\n").utf8))
}
