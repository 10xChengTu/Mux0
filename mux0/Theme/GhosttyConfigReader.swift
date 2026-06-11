import AppKit

/// 解析 ghostty 的配置文件 + 引用的主题文件，提取 background / foreground / palette。
/// 不依赖 libghostty 的 ghostty_config_get（key 行为不明），直接读文本，行为确定。
enum GhosttyConfigReader {

    struct Colors {
        var background: NSColor?
        var foreground: NSColor?
        var palette: [Int: NSColor] = [:]
    }

    /// 默认配置文件位置（按 ghostty 文档顺序探测）。
    static var configPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
            "\(home)/.config/ghostty/config",
        ]
    }

    /// 默认主题搜索路径。用户自定义路径优先，bundle 内置主题（build-vendor.sh 打包）作为 fallback，
    /// 确保 ~/.config/ghostty/themes/<Name> 能覆盖同名 bundle 主题。
    static var themeSearchPaths: [String] {
        let home = NSHomeDirectory()
        var paths: [String] = [
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/themes",
            "\(home)/.config/ghostty/themes",
        ]
        if let base = Bundle.main.resourcePath {
            paths.append((base as NSString).appendingPathComponent("ghostty/themes"))
        }
        return paths
    }

    /// 加载并解析当前用户的 ghostty 配置 + theme 文件 + mux0 override，返回组合后的颜色。
    /// 用户在 config 里直接写的 background/foreground/palette 优先于 theme；
    /// mux0 override 优先于 ghostty 标准 config。
    /// - Parameter systemIsDark: Whether the system (or user preference) is
    ///   currently dark mode. Passed explicitly so the caller controls the source
    ///   of truth — `NSApp.effectiveAppearance` may be stale when read inside an
    ///   `AppleInterfaceThemeChangedNotification` handler.
    static func load(systemIsDark: Bool = false) -> Colors {
        var theme = Colors()
        var direct = Colors()

        // 合并所有来源的 kv，后来的覆盖前面的（ghostty 标准 → mux0 override）。
        var mergedKvs: [(String, String)] = []
        for path in configPaths where FileManager.default.fileExists(atPath: path) {
            mergedKvs.append(contentsOf: parseFile(at: path))
            break
        }
        let mux0Path = SettingsConfigStore.defaultPath
        if FileManager.default.fileExists(atPath: mux0Path) {
            mergedKvs.append(contentsOf: parseFile(at: mux0Path))
        }

        // 最后一个 theme= 为准（mux0 override 会赢）。
        if let themeValue = mergedKvs.reversed().first(where: { $0.0 == "theme" })?.1,
           !themeValue.isEmpty {
            let name = resolveThemeNameForAppearance(themeValue, isDark: systemIsDark)
            if let themePath = locateTheme(named: name) {
                let themeKvs = parseFile(at: themePath)
                applyKVs(themeKvs, into: &theme)
            }
        }

        // direct 字段：顺序覆盖，后来的赢。
        applyKVs(mergedKvs, into: &direct)

        return Colors(
            background: direct.background ?? theme.background,
            foreground: direct.foreground ?? theme.foreground,
            palette: theme.palette.merging(direct.palette) { _, new in new }
        )
    }

    /// 解析 `theme = ...` 的 value，在 follow-system 语法 `light:X,dark:Y` 下
    /// 按传入的 isDark 挑一侧返回；单值直接返回。
    ///
    /// `isDark` 由调用方显式传入，而非内部读取 `NSApp.effectiveAppearance`，
    /// 因为后者在 `AppleInterfaceThemeChangedNotification` 回调中可能仍为旧值。
    private static func resolveThemeNameForAppearance(_ raw: String, isDark: Bool) -> String {
        guard raw.contains(":") && raw.contains(",") else { return raw }
        let wantPrefix = isDark ? "dark:" : "light:"
        for part in raw.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix(wantPrefix) {
                return String(p.dropFirst(wantPrefix.count))
            }
        }
        return raw
    }

    // MARK: - File parsing

    /// 解析 ghostty 配置文件为 (key, value) 对（允许 key 重复，例如 palette）。
    static func parseFile(at path: String) -> [(String, String)] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var result: [(String, String)] = []
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // strip surrounding quotes
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result.append((key, value))
        }
        return result
    }

    private static func applyKVs(_ kvs: [(String, String)], into colors: inout Colors) {
        for (key, value) in kvs {
            switch key {
            case "background":
                if let c = parseColor(value) { colors.background = c }
            case "foreground":
                if let c = parseColor(value) { colors.foreground = c }
            case "palette":
                // value 形如 "3=#df8e1d"
                if let eq = value.firstIndex(of: "="),
                   let idx = Int(value[..<eq]),
                   let c = parseColor(String(value[value.index(after: eq)...])) {
                    colors.palette[idx] = c
                }
            default: break
            }
        }
    }

    // MARK: - Theme lookup

    /// 从用户 config 里解析 `theme = Name`,返回该主题文件的绝对路径。
    /// libghostty 作为独立 dylib 嵌入时没有 `resources-dir`,无法自行解析 `theme = ...`,
    /// GhosttyBridge 会用这个路径再调一次 `ghostty_config_load_file` 作为 override。
    ///
    /// 来源优先级：mux0 override > ghostty 标准 config。这样在设置 UI 里改主题后，
    /// 下一次 reloadConfig 能立即加载正确的主题文件，而不是把旧主题焊在 config 上。
    /// - Parameter isDark: Whether dark mode is active. Falls back to
    ///   `NSApp.effectiveAppearance` when nil (for call sites that are NOT
    ///   inside an `AppleInterfaceThemeChangedNotification` handler).
    static func resolvedThemePath(isDark: Bool? = nil) -> String? {
        let sources: [String] = [SettingsConfigStore.defaultPath] + configPaths
        for path in sources where FileManager.default.fileExists(atPath: path) {
            let kvs = parseFile(at: path)
            guard let themeValue = kvs.first(where: { $0.0 == "theme" })?.1,
                  !themeValue.isEmpty else { continue }
            let dark = isDark ?? (NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let name = resolveThemeNameForAppearance(themeValue, isDark: dark)
            return locateTheme(named: name)
        }
        return nil
    }

    static func locateTheme(named name: String) -> String? {
        for dir in themeSearchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Color parsing

    /// 解析 ghostty 颜色字面值，支持 #rgb / #rrggbb / rgb:rr/gg/bb / 命名色 → nil。
    static func parseColor(_ raw: String) -> NSColor? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        // rgb:rr/gg/bb 形式
        if s.hasPrefix("rgb:") {
            let body = String(s.dropFirst(4))
            let parts = body.components(separatedBy: "/")
            guard parts.count == 3,
                  let r = UInt8(parts[0], radix: 16),
                  let g = UInt8(parts[1], radix: 16),
                  let b = UInt8(parts[2], radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        // hex
        if s.count == 3 {
            // #rgb
            let chars = Array(s)
            let dup = "\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])"
            return parseColor("#" + dup)
        }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8)  & 0xff) / 255
        let b = CGFloat( value        & 0xff) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
