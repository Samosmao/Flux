import Foundation
import Darwin

/// Process-lifetime ownership of Flux's mutable VM state.
///
/// `flock` is released by the kernel if a process dies, so a lock file left
/// behind by a crash is not a stale lock.  Its text is diagnostic only: it
/// records the process that most recently acquired ownership.
nonisolated final class FluxRuntimeLock {

    private let fd: Int32
    private let path: String
    private var isReleased = false

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    static func acquire(appDirectory: String) -> FluxRuntimeLock? {
        let path = appDirectory + "/flux-runtime.lock"
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            print("❌ [FluxRuntimeLock] Cannot open \(path): \(String(cString: strerror(errno)))")
            return nil
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let owner = readOwner(from: fd)
            let ownerDetail = owner.map { " (owner \($0))" } ?? ""
            print("❌ [FluxRuntimeLock] Another Flux VM owns the runtime state\(ownerDetail). Refusing to start.")
            close(fd)
            return nil
        }

        let owner = "pid=\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = owner.withCString { write(fd, $0, strlen($0)) }
        _ = fsync(fd)
        print("🔒 [FluxRuntimeLock] Acquired runtime ownership (pid \(getpid()))")
        return FluxRuntimeLock(fd: fd, path: path)
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        _ = flock(fd, LOCK_UN)
        _ = close(fd)
        print("🔓 [FluxRuntimeLock] Released runtime ownership")
    }

    deinit {
        release()
    }

    private static func readOwner(from fd: Int32) -> String? {
        _ = lseek(fd, 0, SEEK_SET)
        var bytes = [CChar](repeating: 0, count: 128)
        let count = read(fd, &bytes, bytes.count - 1)
        guard count > 0 else { return nil }
        return String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
