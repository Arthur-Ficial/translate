@preconcurrency import Foundation
import Darwin

/// Hard-blocks any HTTP/HTTPS/WS/WSS URLSession request inside the translate
/// process. translate is "100% on-device" by promise; this is the runtime
/// enforcement.
///
/// IMPORTANT: this only intercepts URLSession traffic (URLProtocol does not
/// see the kernel-level sockets that Hummingbird/SwiftNIO open for `--serve`).
/// The HTTP server itself is unaffected — it serves loopback/LAN clients,
/// it does not make outbound network calls.
public enum NetworkGuard: Sendable {
    /// Register the deny-all URLProtocol. Call once, very early in main.
    public static func install() {
        URLProtocol.registerClass(DenyNetworkURLProtocol.self)
    }
}

public enum NetworkScheme: Sendable {
    public static let blocked: Set<String> = ["http", "https", "ws", "wss"]

    public static func isBlocked(_ scheme: String?) -> Bool {
        guard let s = scheme?.lowercased(), !s.isEmpty else { return false }
        return blocked.contains(s)
    }
}

public final class DenyNetworkURLProtocol: URLProtocol, @unchecked Sendable {
    public override class func canInit(with request: URLRequest) -> Bool {
        NetworkScheme.isBlocked(request.url?.scheme)
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        let urlText = request.url?.absoluteString ?? "<unknown>"
        FileHandle.standardError.write(Data("translate: network call blocked: \(urlText)\n".utf8))
        Darwin.exit(2)
    }

    public override func stopLoading() {}
}
