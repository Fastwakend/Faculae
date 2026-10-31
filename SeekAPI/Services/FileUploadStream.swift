import Foundation
import SeekCore

/// File-backed upload tasks still deliver SSE incrementally through data delegate
/// callbacks. Unlike upload(for:fromFile:), the reply is never buffered to the end.
final class FileUploadStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: @unchecked Sendable { case response(HTTPURLResponse), data(Data) }
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionUploadTask?
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
    private var cancelled = false

    func start(_ request: URLRequest, file: URL) -> AsyncThrowingStream<Event, Error> {
        let stream = AsyncThrowingStream<Event, Error>(bufferingPolicy: .bufferingOldest(32)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in self?.cancel() }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.uploadTask(with: request, fromFile: file)
        lock.lock()
        if cancelled {
            lock.unlock(); session.invalidateAndCancel(); continuation?.finish(throwing: CancellationError()); return stream
        }
        self.session = session; self.task = task; lock.unlock()
        task.resume()
        return stream
    }

    func cancel() {
        lock.lock(); cancelled = true; let session = session; let task = task; self.session = nil; self.task = nil; lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            continuation?.finish(throwing: APIError.malformedResponse); completionHandler(.cancel); return
        }
        continuation?.yield(.response(http)); completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if case .dropped = continuation?.yield(.data(data)) {
            continuation?.finish(throwing: APIError.streamTooLarge); cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        session.finishTasksAndInvalidate()
        lock.lock(); self.session = nil; self.task = nil; lock.unlock()
    }
}
