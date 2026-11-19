import Foundation

public struct DownloadResponse: Sendable {
    public let statusCode: Int?
    public let byteCount: Int64
    public let headers: [String: String]

    public init(statusCode: Int?, byteCount: Int64, headers: [String: String]) {
        self.statusCode = statusCode
        self.byteCount = byteCount
        self.headers = headers
    }
}

/// Downloads one asset with progress. URLSession's `progress` object is polled
/// while the task runs so the UI can show a determinate bar without a custom
/// delegate object.
public final class AssetDownloader: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 600
            configuration.httpAdditionalHeaders = ["User-Agent": "Finder7-updater"]
            self.session = URLSession(configuration: configuration)
        }
    }

    public func download(
        _ url: URL,
        to destination: URL,
        expectedSize: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard url.scheme?.lowercased() == "https" else {
            throw EngineUpdateError.downloadFailed(
                destination.lastPathComponent,
                "Refusing a non-HTTPS download URL: \(url.absoluteString)"
            )
        }

        let box = ContinuationBox()
        var request = URLRequest(url: url)
        request.setValue("Finder7-updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let task = session.downloadTask(with: request) { temporaryURL, response, error in
            if let error {
                box.resume(.failure(error))
                return
            }
            guard let temporaryURL else {
                box.resume(.failure(EngineUpdateError.downloadFailed(
                    destination.lastPathComponent,
                    "The server returned no file."
                )))
                return
            }
            let http = response as? HTTPURLResponse
            let headers = http.map { response in
                Dictionary(uniqueKeysWithValues: response.allHeaderFields.map {
                    (String(describing: $0.key).lowercased(), String(describing: $0.value))
                })
            } ?? [:]
            guard let http, (200...299).contains(http.statusCode) else {
                box.resume(.failure(EngineUpdateError.httpStatus(
                    http?.statusCode ?? -1,
                    "Downloading \(destination.lastPathComponent)"
                )))
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: temporaryURL, to: destination)
                let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
                if let expectedSize, size != expectedSize {
                    throw EngineUpdateError.sizeMismatch(
                        destination.lastPathComponent,
                        expected: expectedSize,
                        actual: size
                    )
                }
                box.resume(.success(DownloadResponse(
                    statusCode: http.statusCode,
                    byteCount: size,
                    headers: headers
                )))
            } catch {
                box.resume(.failure(error))
            }
        }

        let monitor = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { break }
                let value = task.progress.fractionCompleted
                if value.isFinite, value >= 0 {
                    progress(min(max(value, 0), 1))
                }
            }
        }
        defer { monitor.cancel() }

        do {
            _ = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DownloadResponse, Error>) in
                    box.set(continuation)
                    task.resume()
                }
            }, onCancel: {
                task.cancel()
            })
        } catch {
            if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                throw EngineUpdateError.cancelled
            }
            if let updateError = error as? EngineUpdateError { throw updateError }
            throw EngineUpdateError.downloadFailed(
                destination.lastPathComponent,
                error.localizedDescription
            )
        }
    }
}

private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DownloadResponse, Error>?

    func set(_ continuation: CheckedContinuation<DownloadResponse, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ result: Result<DownloadResponse, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
