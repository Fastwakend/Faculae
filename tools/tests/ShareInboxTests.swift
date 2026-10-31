import Foundation

@main
struct ShareInboxTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(root: root)
        func require(_ condition: @autoclosure () throws -> Bool) rethrows {
            let result = try condition(); precondition(result)
        }
        var passed = 0
        func check(_ title: String, _ action: () throws -> Void) rethrows {
            try action(); passed += 1; print("PASS: \(title)")
        }
        func rejects(_ action: () throws -> Void) {
            do { try action(); fatalError("Expected rejection") } catch {}
        }
        var batch = try inbox.begin()
        try check("Uncommitted provider files are invisible") {
            try inbox.add(Data("hello".utf8), name: "note.txt", to: &batch)
            try require(try inbox.pending().isEmpty)
        }
        try check("Committed multi-file batch survives a fresh reader") {
            try inbox.add(Data([1, 2, 3]), name: "picture.png", to: &batch)
            try inbox.commit(batch)
            let reader = ShareInbox(root: root)
            try require(try reader.pending() == [batch])
            try require(try Data(contentsOf: reader.urls(batch)[0]) == Data("hello".utf8))
        }
        try check("Traversal provider names never escape the batch directory") {
            var other = try inbox.begin()
            try inbox.add(Data([1]), name: "../../nested\\bad.txt", to: &other)
            let urls = try inbox.urls(other)
            assert(urls[0].deletingLastPathComponent() == inbox.folder(other))
            assert(!other.files[0].contains("\\"))
        }
        check("Manifest traversal and symlinks are rejected") {
            let malicious = ShareInbox.Batch(id: batch.id, createdAt: Date(), files: ["../manifest.json"])
            rejects { _ = try inbox.urls(malicious) }
            let link = inbox.folder(batch).appendingPathComponent("link")
            try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            let symlink = ShareInbox.Batch(id: batch.id, createdAt: Date(), files: ["link"])
            rejects { _ = try inbox.urls(symlink) }
        }
        try check("Empty and oversized files fail without becoming visible") {
            var other = try inbox.begin()
            rejects { try inbox.add(Data(), name: "empty.txt", to: &other) }
            let big = root.appendingPathComponent("oversize")
            require(FileManager.default.createFile(atPath: big.path, contents: nil))
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: UInt64(ShareInbox.fileLimit + 1)); try handle.close()
            rejects { try inbox.add(big, name: "big.bin", to: &other) }
            assert(other.files.isEmpty)
        }
        try check("File count is limited to six") {
            var other = try inbox.begin()
            for _ in 0..<6 { try inbox.add(Data([1]), name: "same.txt", to: &other) }
            rejects { try inbox.add(Data([1]), name: "seventh.txt", to: &other) }
            assert(Set(other.files).count == 6)
        }
        try check("One-gigabyte boundary is accepted without allocating it in memory") {
            var other = try inbox.begin()
            try inbox.add(Data([1]), name: "a.bin", to: &other)
            let file = try inbox.urls(other)[0]
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(ShareInbox.fileLimit)); try handle.close()
            try require(try inbox.urls(other) == [file])
            require(ShareInbox.totalLimit == 6 * ShareInbox.fileLimit)
        }
        try check("Local provider copy remains readable after the original disappears") {
            let original = root.appendingPathComponent("temporary.txt")
            try Data("provider".utf8).write(to: original)
            var other = try inbox.begin()
            try inbox.add(original, to: &other)
            try FileManager.default.removeItem(at: original)
            try require(try Data(contentsOf: inbox.urls(other)[0]) == Data("provider".utf8))
        }
        try check("Bounded file copy rejects folders and files over limit") {
            var other = try inbox.begin()
            rejects { try inbox.add(root, to: &other) }
            let big = root.appendingPathComponent("large")
            require(FileManager.default.createFile(atPath: big.path, contents: nil))
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: UInt64(ShareInbox.fileLimit + 1)); try handle.close()
            rejects { try inbox.add(big, to: &other) }
        }
        try check("Consuming a batch removes only that batch") {
            try inbox.remove(batch)
            assert(!FileManager.default.fileExists(atPath: inbox.folder(batch).path))
            assert(FileManager.default.fileExists(atPath: root.path))
        }
        print("Passed \(passed) share-inbox regression cases; failures: 0")
    }
}
