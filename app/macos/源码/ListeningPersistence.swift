import Foundation

/// Serializes and coalesces automatic audition saves without publishing UI state off the main thread.
final class ListeningPersistence {
    struct Completion {
        let update: ListeningUpdate
        let result: Result<(project: ProjectRecord, document: LibraryDocument), Error>
    }

    private let library: LibraryStore
    private let queue = DispatchQueue(label: "local.aiden.xianwaiwu.listening", qos: .utility)
    private let lock = NSLock()
    private var pending: ListeningUpdate?
    private var running = false
    private var completed: [Completion] = []
    var onCompletion: (() -> Void)?

    init(library: LibraryStore) { self.library = library }

    func enqueue(_ update: ListeningUpdate) {
        lock.lock()
        pending = update
        let shouldStart = !running
        running = true
        lock.unlock()
        if shouldStart { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let update = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            let result = Result { try library.persistListening(update) }
            lock.lock()
            completed.append(Completion(update: update, result: result))
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onCompletion?() }
        }
    }

    func takeCompletions() -> [Completion] {
        lock.lock(); defer { lock.unlock() }
        let values = completed
        completed.removeAll(keepingCapacity: true)
        return values
    }

    /// Explicit navigation, export, and quit wait for earlier automatic saves before changing records.
    /// The worker never synchronously enters the main queue, so this cannot create a queue cycle.
    func flush() { queue.sync {} }
}
