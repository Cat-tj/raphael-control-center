import Foundation
import AppKit

struct RFile: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDir: Bool
    let isLink: Bool
    let size: Int64
    let modified: Date
    let mode: String
    let owner: String

    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg", "ico"].contains(ext) }
    var icon: String {
        if isDir { return isLink ? "folder.badge.gearshape" : "folder.fill" }
        if isImage { return "photo" }
        switch ext {
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tgz", "tar", "xz", "7z", "bz2": return "archivebox"
        case "sh", "py", "js", "ts", "swift", "go", "rs", "rb", "php", "sql": return "chevron.left.forwardslash.chevron.right"
        case "log": return "list.bullet.rectangle"
        case "yml", "yaml", "json", "toml", "conf", "ini", "env", "service": return "gearshape"
        case "md", "txt": return "doc.text"
        case "db", "sqlite", "sqlite3": return "cylinder"
        default: return isLink ? "link" : "doc"
        }
    }
}

/// Browse, read, edit, download and upload files on any device: this Mac directly,
/// other devices over SSH (python3 for listings, scp for transfers).
enum FilesStore {
    struct Listing { var path: String; var home: String; var items: [RFile]; var error: String? }

    static func list(_ node: RNode, _ path: String, sudo: Bool) async -> Listing {
        if node.isLocal { return localList(path) }
        let py = """
        import json, os, stat, sys, pwd, grp
        p = os.path.realpath(os.path.expanduser(\(DeviceContext.pyString(path.isEmpty ? "~" : path))))
        out, err = [], None
        try:
            for e in os.scandir(p):
                try:
                    st = e.stat(follow_symlinks=False)
                    isdir = e.is_dir()
                    try: owner = pwd.getpwuid(st.st_uid).pw_name
                    except Exception: owner = str(st.st_uid)
                    out.append([e.name, isdir, stat.S_ISLNK(st.st_mode), st.st_size, st.st_mtime, stat.filemode(st.st_mode), owner])
                except Exception: pass
        except Exception as ex: err = str(ex)
        print(json.dumps({"path": p, "home": os.path.expanduser("~"), "items": out, "error": err}))
        """
        let r = await DeviceContext.run(node, "\(sudo ? "sudo -n " : "")python3 - <<'RAPHAEL_PY'\n\(py)\nRAPHAEL_PY", timeout: 30)
        guard let line = r.output.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return Listing(path: path, home: "", items: [], error: r.output.isEmpty ? "Tidak terhubung" : String(r.output.suffix(300)))
        }
        let base = j["path"] as? String ?? path
        let items = (j["items"] as? [[Any]] ?? []).compactMap { a -> RFile? in
            guard a.count >= 7, let name = a[0] as? String else { return nil }
            return RFile(name: name, path: (base as NSString).appendingPathComponent(name), isDir: a[1] as? Bool ?? false,
                         isLink: a[2] as? Bool ?? false, size: (a[3] as? NSNumber)?.int64Value ?? 0,
                         modified: Date(timeIntervalSince1970: (a[4] as? NSNumber)?.doubleValue ?? 0),
                         mode: a[5] as? String ?? "", owner: a[6] as? String ?? "")
        }
        return Listing(path: base, home: j["home"] as? String ?? "", items: items, error: j["error"] as? String)
    }

    private static func localList(_ path: String) -> Listing {
        let fm = FileManager.default
        let p = URL(fileURLWithPath: ((path.isEmpty ? "~" : path) as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        do {
            let names = try fm.contentsOfDirectory(atPath: p)
            let items = names.compactMap { name -> RFile? in
                let full = (p as NSString).appendingPathComponent(name)
                guard let a = try? fm.attributesOfItem(atPath: full) else { return nil }
                let type = a[.type] as? FileAttributeType
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                let perms = (a[.posixPermissions] as? NSNumber)?.intValue ?? 0
                return RFile(name: name, path: full, isDir: isDir.boolValue, isLink: type == .typeSymbolicLink,
                             size: (a[.size] as? NSNumber)?.int64Value ?? 0, modified: a[.modificationDate] as? Date ?? .distantPast,
                             mode: (isDir.boolValue ? "d" : "-") + modeString(perms), owner: a[.ownerAccountName] as? String ?? "")
            }
            return Listing(path: p, home: NSHomeDirectory(), items: items)
        } catch {
            return Listing(path: p, home: NSHomeDirectory(), items: [], error: error.localizedDescription)
        }
    }

    private static func modeString(_ m: Int) -> String {
        var s = ""
        for shift in [6, 3, 0] {
            let v = (m >> shift) & 7
            s += (v & 4 != 0 ? "r" : "-") + (v & 2 != 0 ? "w" : "-") + (v & 1 != 0 ? "x" : "-")
        }
        return s
    }

    /// Text content (nil when binary or bigger than `limit`).
    static func readText(_ node: RNode, _ path: String, sudo: Bool, limit: Int = 2_000_000) async -> (text: String?, error: String?) {
        if node.isLocal {
            guard let data = FileManager.default.contents(atPath: path) else { return (nil, "Tidak bisa dibaca") }
            if data.count > limit { return (nil, "File terlalu besar untuk ditampilkan (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))") }
            return String(data: data, encoding: .utf8).map { ($0, nil) } ?? (nil, "File biner")
        }
        let py = """
        import base64, json, os
        p = \(DeviceContext.pyString(path))
        try:
            n = os.path.getsize(p)
            if n > \(limit): print(json.dumps({"error": "big", "size": n}))
            else:
                b = open(p, 'rb').read()
                try: b.decode('utf-8'); print(json.dumps({"b64": base64.b64encode(b).decode()}))
                except UnicodeDecodeError: print(json.dumps({"error": "binary"}))
        except Exception as e: print(json.dumps({"error": str(e)}))
        """
        let r = await DeviceContext.run(node, "\(sudo ? "sudo -n " : "")python3 - <<'RAPHAEL_PY'\n\(py)\nRAPHAEL_PY", timeout: 60)
        guard let line = r.output.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return (nil, "Tidak terhubung") }
        if let b = j["b64"] as? String, let d = Data(base64Encoded: b) { return (String(decoding: d, as: UTF8.self), nil) }
        switch j["error"] as? String {
        case "big": return (nil, "File terlalu besar untuk ditampilkan (\(ByteCountFormatter.string(fromByteCount: (j["size"] as? NSNumber)?.int64Value ?? 0, countStyle: .file)))")
        case "binary": return (nil, "File biner")
        case let e?: return (nil, e)
        default: return (nil, "Tidak bisa dibaca")
        }
    }

    static func save(_ node: RNode, _ path: String, _ text: String) async -> Bool {
        await DeviceContext.writeFile(node, path, text)
    }

    // MARK: Transfers

    private static func scpArgs(_ node: RNode) -> [String] {
        var a = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-r", "-p"]
        if let j = node.jump, !j.isEmpty { a += ["-J", j] }
        return a
    }

    /// Copies a remote file/folder to a local folder; returns the local URL.
    static func download(_ node: RNode, _ file: RFile, to dir: URL) async -> (URL?, String?) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(file.name)
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\((file.name as NSString).deletingPathExtension) \(i)" + (file.ext.isEmpty ? "" : ".\(file.ext)")); i += 1
        }
        if node.isLocal {
            do { try FileManager.default.copyItem(atPath: file.path, toPath: dest.path); return (dest, nil) } catch { return (nil, error.localizedDescription) }
        }
        let r = await NodeStore.runProcess("/usr/bin/scp", scpArgs(node) + ["\(node.ssh):\(file.path)", dest.path], timeout: 1800)
        return r.exitCode == 0 ? (dest, nil) : (nil, String(r.output.suffix(300)))
    }

    /// Downloads into a cache folder and opens it with the default Mac app.
    static func open(_ node: RNode, _ file: RFile) async -> String? {
        if node.isLocal { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)); return nil }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Raphael/files/\(node.id)/\(UUID().uuidString.prefix(8))")
        let (url, err) = await download(node, file, to: cache)
        if let url { NSWorkspace.shared.open(url) }
        return err
    }

    static func upload(_ node: RNode, _ urls: [URL], to dir: String) async -> String? {
        if node.isLocal {
            for u in urls {
                do { try FileManager.default.copyItem(at: u, to: URL(fileURLWithPath: dir).appendingPathComponent(u.lastPathComponent)) }
                catch { return error.localizedDescription }
            }
            return nil
        }
        let r = await NodeStore.runProcess("/usr/bin/scp", scpArgs(node) + urls.map(\.path) + ["\(node.ssh):\(dir.hasSuffix("/") ? dir : dir + "/")"], timeout: 3600)
        return r.exitCode == 0 ? nil : String(r.output.suffix(300))
    }

    // MARK: Changes

    static func mkdir(_ node: RNode, _ path: String) async -> String? {
        if node.isLocal {
            do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) } catch { return error.localizedDescription }
            return nil
        }
        let r = await DeviceContext.run(node, "mkdir -- \(NodeStore.shellQuote(path))", timeout: 20)
        return r.exitCode == 0 ? nil : r.output
    }

    static func rename(_ node: RNode, _ from: String, _ to: String) async -> String? {
        if node.isLocal {
            do { try FileManager.default.moveItem(atPath: from, toPath: to) } catch { return error.localizedDescription }
            return nil
        }
        let r = await DeviceContext.run(node, "mv -n -- \(NodeStore.shellQuote(from)) \(NodeStore.shellQuote(to)) && test -e \(NodeStore.shellQuote(to))", timeout: 20)
        return r.exitCode == 0 ? nil : (r.output.isEmpty ? "Nama sudah dipakai" : r.output)
    }

    /// Not a hard delete: moves into the Trash (Mac) or ~/.raphael-trash/<time>/ (server).
    static func trash(_ node: RNode, _ files: [RFile]) async -> String? {
        if node.isLocal {
            for f in files {
                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil) } catch { return error.localizedDescription }
            }
            return nil
        }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime]).replacingOccurrences(of: ":", with: "")
        let paths = files.map { NodeStore.shellQuote($0.path) }.joined(separator: " ")
        let r = await DeviceContext.run(node, "d=~/.raphael-trash/\(stamp); mkdir -p \"$d\" && mv -- \(paths) \"$d\"/ && echo \"$d\"", timeout: 60)
        return r.exitCode == 0 ? nil : r.output
    }
}
