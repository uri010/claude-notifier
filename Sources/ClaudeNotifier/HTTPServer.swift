import Foundation

/// A minimal blocking HTTP/1.1 server built on BSD sockets.
/// One thread per connection. Sufficient for localhost hook traffic.
final class HTTPServer {
    private let port: UInt16
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "claude.notifier.http.accept")
    private let workerQueue = DispatchQueue(label: "claude.notifier.http.worker", attributes: .concurrent)
    private var running = false

    /// Handler: (method, path, body) -> (statusCode, contentType, responseBody)
    var handler: ((String, String, Data) -> (Int, String, Data))?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1") // localhost only

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.bindFailed(errno)
        }
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw ServerError.listenFailed(errno)
        }

        listenFD = fd
        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if !running { break }
                continue
            }
            workerQueue.async { [weak self] in
                self?.handleConnection(client)
            }
        }
    }

    private func handleConnection(_ client: Int32) {
        defer { close(client) }
        // Read until we have headers + full body.
        var buffer = Data()
        var headerEnd: Range<Data.Index>? = nil
        let chunkSize = 4096
        var tmp = [UInt8](repeating: 0, count: chunkSize)

        // Read headers first.
        while headerEnd == nil {
            let n = recv(client, &tmp, chunkSize, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: tmp[0..<n])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if buffer.count > 1_048_576 { return } // 1MB header cap
        }

        guard let hEnd = headerEnd else { return }
        let headerData = buffer.subdata(in: 0..<hEnd.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let method = parts[0]
        let path = parts[1]

        // Content-Length.
        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(val) ?? 0
            }
        }

        var body = buffer.subdata(in: hEnd.upperBound..<buffer.endIndex)
        let maxBody = 1_048_576 // 1 MB body limit
        while body.count < contentLength {
            if body.count >= maxBody {
                sendResponse(client, status: 413, contentType: "text/plain",
                             body: Data("Request body too large".utf8))
                return
            }
            let n = recv(client, &tmp, chunkSize, 0)
            if n <= 0 { break }
            body.append(contentsOf: tmp[0..<n])
        }

        let (status, contentType, respBody) = handler?(method, path, body) ?? (404, "text/plain", Data("not found".utf8))
        sendResponse(client, status: status, contentType: contentType, body: respBody)
    }

    private func sendResponse(_ client: Int32, status: Int, contentType: String, body: Data) {
        let statusText = HTTPServer.statusText(status)
        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        var out = Data(header.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            var sent = 0
            let total = raw.count
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < total {
                let n = send(client, base + sent, total - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    enum ServerError: Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
    }
}
