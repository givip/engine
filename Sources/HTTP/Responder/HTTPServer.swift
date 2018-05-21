/// Simple HTTP server generic on an HTTP responder
/// that will be used to generate responses to incoming requests.
///
///     let server = try HTTPServer.start(hostname: hostname, port: port, responder: EchoResponder(), on: group).wait()
///     try server.onClose.wait()
///
public final class HTTPServer {
    // MARK: Static

    /// Starts the server on the supplied hostname and port, using the supplied
    /// responder to generate HTTP responses for incoming requests.
    ///
    ///     let server = try HTTPServer.start(hostname: hostname, port: port, responder: EchoResponder(), on: group).wait()
    ///     try server.onClose.wait()
    ///
    /// - parameters:
    ///     - hostname: Socket hostname to bind to. Usually `localhost` or `::1`.
    ///     - port: Socket port to bind to. Usually `8080` for development and `80` for production.
    ///     - responder: Used to generate responses for incoming requests.
    ///     - maxBodySize: Requests with bodies larger than this maximum will be rejected.
    ///                    Streaming bodies, like chunked bodies, ignore this maximum.
    ///     - backlog: OS socket backlog size.
    ///     - reuseAddress: When `true`, can prevent errors re-binding to a socket after successive server restarts.
    ///     - tcpNoDelay: When `true`, OS will attempt to minimize TCP packet delay.
    ///     - upgraders: An array of `HTTPProtocolUpgrader` to check for with each request.
    ///     - worker: `Worker` to perform async work on.
    ///     - onError: Any uncaught server or responder errors will go here.
    public static func start<R>(
        hostname: String,
        port: Int,
        responder: R,
        tlsConfig: TLSConfiguration? = nil,
        maxBodySize: Int = 1_000_000,
        backlog: Int = 256,
        reuseAddress: Bool = true,
        tcpNoDelay: Bool = true,
        upgraders: [HTTPProtocolUpgrader] = [],
        on worker: Worker,
        onError: @escaping (Error) -> () = { _ in }
    ) -> Future<HTTPServer> where R: HTTPServerResponder {
        let bootstrap = ServerBootstrap(group: worker)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: Int32(backlog))
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: reuseAddress ? SocketOptionValue(1) : SocketOptionValue(0))

            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer { channel in
                var tlsHandler: OpenSSLServerHandler?
                if let tls = tlsConfig {
                    let sslContext = try! SSLContext(configuration: tls)
                    tlsHandler = try! OpenSSLServerHandler(context: sslContext)
                }
                
                // create HTTPServerResponder-based handler
                let handler = HTTP.HTTPServerHandler(responder: responder, maxBodySize: maxBodySize, onError: onError)
                
                // re-use subcontainer for an event loop here
                let upgrade: HTTPUpgradeConfiguration = (upgraders: upgraders, completionHandler: { ctx in
                    // shouldn't need to wait for this
                    _ = channel.pipeline.remove(handler: handler)
                    if let handler = tlsHandler {
                        _ = channel.pipeline.remove(handler: handler)
                    }
                })

                // configure the pipeline
                let server = channel.pipeline
                    .configureHTTPServerPipeline(
                        withPipeliningAssistance: false,
                        withServerUpgrade: upgrade,
                        withErrorHandling: false
                    )
                    .then {
                        return channel.pipeline.add(handler: handler)
                }
                
                if let tls = tlsHandler {
                    return server.then {
                        return channel.pipeline.addHandlers(tls, first: true)
                    }
                }
                
                return server
            }

            // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: tcpNoDelay ? SocketOptionValue(1) : SocketOptionValue(0))
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: reuseAddress ? SocketOptionValue(1) : SocketOptionValue(0))
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            // .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: 1)

        return bootstrap.bind(host: hostname, port: port).map(to: HTTPServer.self) { channel in
            return HTTPServer(channel: channel)
        }
    }

    // MARK: Properties

    /// A future that will be signaled when the server closes.
    public var onClose: Future<Void> {
        return channel.closeFuture
    }

    /// The running channel.
    private var channel: Channel

    /// Creates a new `HTTPServer`. Use the public static `.start` method.
    private init(channel: Channel) {
        self.channel = channel
    }

    // MARK: Methods

    /// Closes the server.
    public func close() -> Future<Void> {
        return channel.close(mode: .all)
    }
}

// MARK: Private

/// Private `ChannelInboundHandler` that converts `HTTPServerRequestPart` to `HTTPServerResponsePart`.
private final class HTTPServerHandler<R>: ChannelInboundHandler where R: HTTPServerResponder {
    /// See `ChannelInboundHandler`.
    public typealias InboundIn = HTTPServerRequestPart

    /// See `ChannelInboundHandler`.
    public typealias OutboundOut = HTTPServerResponsePart

    /// The responder generating `HTTPResponse`s for incoming `HTTPRequest`s.
    public let responder: R

    /// Maximum body size allowed per request.
    private let maxBodySize: Int

    /// Handles any errors that may occur.
    private let errorHandler: (Error) -> ()

    /// Caches RFC1123 dates for performant serialization
    private var dateCache: RFC1123DateCache

    /// Current HTTP state.
    var state: HTTPServerState

    /// Create a new `HTTPServerHandler`.
    init(responder: R, maxBodySize: Int = 1_000_000, onError: @escaping (Error) -> ()) {
        self.responder = responder
        self.maxBodySize = maxBodySize
        self.errorHandler = onError
        self.dateCache = .init()
        self.state = .ready
    }

    /// See `ChannelInboundHandler`.
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        debugOnly { assert(ctx.channel.eventLoop.inEventLoop) }
        switch unwrapInboundIn(data) {
        case .head(let head):
            debugOnly {
                /// only perform this switch in debug mode
                switch state {
                case .ready: break
                default: assertionFailure("Unexpected state: \(state)")
                }
            }
            state = .awaitingBody(head)
        case .body(var chunk):
            switch state {
            case .ready: debugOnly { assertionFailure("Unexpected state: \(state)") }
            case .awaitingBody(let head):
                /// 1: check to see which kind of body we are parsing from the head
                ///
                /// short circuit on `contains(name:)` which is faster
                /// - note: for some reason using String instead of HTTPHeaderName is faster here...
                ///         this will be standardized when NIO gets header names
                if head.headers.contains(name: "Transfer-Encoding"), head.headers.firstValue(name: .transferEncoding) == "chunked" {
                    let stream = HTTPChunkedStream(on: ctx.eventLoop)
                    state = .streamingBody(stream)
                    respond(to: head, body: .init(chunked: stream), ctx: ctx)
                } else {
                    state = .collectingBody(head, nil)
                }

                /// 2: perform the actual body read now
                channelRead(ctx: ctx, data: data)
            case .collectingBody(let head, let existingBody):
                let body: ByteBuffer
                if var existing = existingBody {
                    if existing.readableBytes + chunk.readableBytes > self.maxBodySize {
                        ERROR("[HTTP] Request size exceeded maximum, connection closed.")
                        ctx.close(promise: nil)
                    }
                    existing.write(buffer: &chunk)
                    body = existing
                } else {
                    body = chunk
                }
                state = .collectingBody(head, body)
            case .streamingBody(let stream): _ = stream.write(.chunk(chunk))
            }
        case .end(let tailHeaders):
            debugOnly { assert(tailHeaders == nil, "Tail headers are not supported.") }
            switch state {
            case .ready: debugOnly { assertionFailure("Unexpected state: \(state)") }
            case .awaitingBody(let head): respond(to: head, body: .empty, ctx: ctx)
            case .collectingBody(let head, let body):
                let body: HTTPBody = body.flatMap(HTTPBody.init(buffer:)) ?? .empty
                respond(to: head, body: body, ctx: ctx)
            case .streamingBody(let stream): _ = stream.write(.end)
            }
            state = .ready
        }
    }

    /// Requests an `HTTPResponse` from the responder and serializes it.
    private func respond(to head: HTTPRequestHead, body: HTTPBody, ctx: ChannelHandlerContext) {
        var req = HTTPRequest(head: head, body: body, channel: ctx.channel)
        switch head.method {
        case .HEAD: req.method = .GET
        default: break
        }
        let res = responder.respond(to: req, on: ctx.eventLoop)
        res.whenSuccess { res in
            debugOnly {
                switch body.storage {
                case .chunkedStream(let stream):
                    if !stream.isClosed {
                        ERROR("HTTPResponse sent while HTTPRequest had unconsumed chunked data.")
                    }
                default: break
                }
            }
            self.serialize(res, for: head, ctx: ctx)
        }
        res.whenFailure { error in
            self.errorHandler(error)
            ctx.close(promise: nil)
        }
    }

    /// Serializes the `HTTPResponse`.
    private func serialize(_ res: HTTPResponse, for reqhead: HTTPRequestHead, ctx: ChannelHandlerContext) {
        // add a RFC1123 timestamp to the Date header to make this
        // a valid request
        var reshead = res.head
        reshead.headers.add(name: "date", value: dateCache.currentTimestamp())

        // begin serializing
        ctx.write(wrapOutboundOut(.head(reshead)), promise: nil)
        if reqhead.method == .HEAD {
            // skip sending the body for HEAD requests
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        } else {
            switch res.body.storage {
            case .none: ctx.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            case .buffer(let buffer): writeAndflush(buffer: buffer, ctx: ctx)
            case .string(let string):
                var buffer = ctx.channel.allocator.buffer(capacity: string.count)
                buffer.write(string: string)
                writeAndflush(buffer: buffer, ctx: ctx)
            case .staticString(let string):
                var buffer = ctx.channel.allocator.buffer(capacity: string.count)
                buffer.write(staticString: string)
                writeAndflush(buffer: buffer, ctx: ctx)
            case .data(let data):
                var buffer = ctx.channel.allocator.buffer(capacity: data.count)
                buffer.write(bytes: data)
                writeAndflush(buffer: buffer, ctx: ctx)
            case .dispatchData(let data):
                var buffer = ctx.channel.allocator.buffer(capacity: data.count)
                buffer.write(bytes: data)
                writeAndflush(buffer: buffer, ctx: ctx)
            case .chunkedStream(let stream):
                stream.read { result, stream in
                    switch result {
                    case .chunk(let buffer): return ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))))
                    case .end: return ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)))
                    case .error(let error):
                        self.errorHandler(error)
                        return ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)))
                    }
                }
            }
        }
    }
    /// Writes a `ByteBuffer` to the ctx.
    private func writeAndflush(buffer: ByteBuffer, ctx: ChannelHandlerContext) {
        if buffer.readableBytes > 0 {
            ctx.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        ctx.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// See `ChannelInboundHandler`.
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        errorHandler(error)
    }
}

/// Tracks current HTTP server state
private enum HTTPServerState {
    /// Waiting for request headers
    case ready
    /// Waiting for the body
    /// This allows for performance optimization incase
    /// a body never comes
    case awaitingBody(HTTPRequestHead)
    /// Collecting fixed-length body
    case collectingBody(HTTPRequestHead, ByteBuffer?)
    /// Collecting streaming body
    case streamingBody(HTTPChunkedStream)
}
