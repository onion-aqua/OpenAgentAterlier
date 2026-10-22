import Cocoa
import FlutterMacOS
import Network
import WebKit

private let live2DViewType = "live2d_view"
private let cubismCoreURL = "https://cubism.live2d.com/sdk-web/core/06/live2dcubismcore.min.js"

private enum Live2DLog {
    static func write(viewId: Int64? = nil, _ message: String) {
        let view = viewId.map { "[view:\($0)]" } ?? ""
        let line = "[FlutterLive2D][macOS]\(view) \(message)\n"
        line.withCString { fputs($0, stderr) }
        fflush(stderr)
    }
}

public class FlutterLive2dPlugin: NSObject, FlutterPlugin {
    private var views: [Int64: WeakLive2DView] = [:]
    private let assetRoot: URL?

    init(assetRoot: URL?) {
        self.assetRoot = assetRoot
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let runtimeKey = registrar.lookupKey(
            forAsset: "assets/web/flutter_live2d_web.js",
            fromPackage: "live2d_flutter")
        let runtimeURL = flutterAssetURL(for: runtimeKey)
        Live2DLog.write("register runtime=\(runtimeURL?.path ?? "not-found")")
        let instance = FlutterLive2dPlugin(assetRoot: runtimeURL?.deletingLastPathComponent())
        let channel = FlutterMethodChannel(
            name: "flutter_live2d",
            binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.register(
            Live2DViewFactory(plugin: instance),
            withId: live2DViewType)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        case "getPlatformVersion":
            result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
        case "getTempDirectory":
            result(NSTemporaryDirectory())
        case "loadModel":
            guard let view = requiredView(args, result: result),
                  let modelDir = requiredString(args, name: "modelDir", result: result),
                  let fileName = requiredString(args, name: "modelFileName", result: result) else {
                return
            }
            view.loadModel(modelDir: modelDir, fileName: fileName) { commandResult in
                self.finish(commandResult, flutterResult: result)
            }
        case "unloadModel":
            perform(args, result: result) { view, completion in
                view.command("unloadModel", arguments: [], completion: completion)
            }
        case "setRenderingPaused":
            guard let paused = args?["paused"] as? Bool else {
                result(invalidArguments("Missing or invalid 'paused'."))
                return
            }
            perform(args, result: result) { view, completion in
                view.command("setRenderingPaused", arguments: [paused], completion: completion)
            }
        case "startMotion":
            guard let group = args?["group"] as? String else {
                result(invalidArguments("Missing or invalid 'group'."))
                return
            }
            let index = (args?["index"] as? NSNumber)?.intValue ?? 0
            let priority = (args?["priority"] as? NSNumber)?.intValue ?? 2
            perform(args, result: result) { view, completion in
                view.command(
                    "startMotion",
                    arguments: [group, index, priority],
                    completion: completion)
            }
        case "setExpression":
            let index = (args?["index"] as? NSNumber)?.intValue ?? 0
            perform(args, result: result) { view, completion in
                view.command("setExpression", arguments: [index], completion: completion)
            }
        case "setParameter":
            guard let parameterId = requiredString(
                args, name: "parameterId", result: result) else {
                return
            }
            let value = (args?["value"] as? NSNumber)?.doubleValue ?? 0
            perform(args, result: result) { view, completion in
                view.command(
                    "setParameter",
                    arguments: [parameterId, value],
                    completion: completion)
            }
        case "setMotionSpeed":
            let speed = (args?["speed"] as? NSNumber)?.doubleValue ?? 1
            perform(args, result: result) { view, completion in
                view.command("setMotionSpeed", arguments: [speed], completion: completion)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    fileprivate func createView(viewId: Int64) -> NSView {
        let view = Live2DWebView(viewId: viewId, assetRoot: assetRoot)
        views[viewId] = WeakLive2DView(view)
        return view
    }

    private func perform(
        _ args: [String: Any]?,
        result: @escaping FlutterResult,
        operation: (Live2DWebView, @escaping Live2DCommandCompletion) -> Void
    ) {
        guard let view = requiredView(args, result: result) else { return }
        operation(view) { commandResult in
            self.finish(commandResult, flutterResult: result)
        }
    }

    private func requiredView(
        _ args: [String: Any]?,
        result: @escaping FlutterResult
    ) -> Live2DWebView? {
        guard let viewId = (args?["viewId"] as? NSNumber)?.int64Value else {
            result(invalidArguments("Missing or invalid 'viewId'."))
            return nil
        }
        guard let view = views[viewId]?.value else {
            views.removeValue(forKey: viewId)
            result(FlutterError(
                code: "VIEW_NOT_FOUND",
                message: "No Live2D view registered for id \(viewId).",
                details: nil))
            return nil
        }
        return view
    }

    private func requiredString(
        _ args: [String: Any]?,
        name: String,
        result: @escaping FlutterResult
    ) -> String? {
        guard let value = args?[name] as? String, !value.isEmpty else {
            result(invalidArguments("Missing or empty '\(name)'."))
            return nil
        }
        return value
    }

    private func finish(
        _ result: Result<Any?, Error>,
        flutterResult: @escaping FlutterResult
    ) {
        switch result {
        case .success(let value):
            flutterResult(value)
        case .failure(let error):
            flutterResult(FlutterError(
                code: "NATIVE_ERROR",
                message: error.localizedDescription,
                details: nil))
        }
    }

    private func invalidArguments(_ message: String) -> FlutterError {
        FlutterError(code: "INVALID_ARGS", message: message, details: nil)
    }
}

private final class WeakLive2DView {
    weak var value: Live2DWebView?

    init(_ value: Live2DWebView) {
        self.value = value
    }
}

private final class Live2DViewFactory: NSObject, FlutterPlatformViewFactory {
    private weak var plugin: FlutterLive2dPlugin?

    init(plugin: FlutterLive2dPlugin) {
        self.plugin = plugin
        super.init()
    }

    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        plugin?.createView(viewId: viewId) ?? NSView()
    }
}

private typealias Live2DCommandCompletion = (Result<Any?, Error>) -> Void

private struct PendingCommand {
    let name: String
    let startedAt: Date
    let completion: Live2DCommandCompletion
}

private final class Live2DWebView: NSView, WKScriptMessageHandler, WKNavigationDelegate {
    private let viewId: Int64
    private let server: Live2DLocalServer
    private let webView: WKWebView
    private var messageHandler: WeakScriptMessageHandler?
    private var isReady = false
    private var loadError: Error?
    private var readyOperations: [ReadyOperation] = []
    private var pendingCommands: [String: PendingCommand] = [:]

    init(viewId: Int64, assetRoot: URL?) {
        self.viewId = viewId
        server = Live2DLocalServer(viewId: viewId, assetRoot: assetRoot)

        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        let messageHandler = WeakScriptMessageHandler(delegate: self)
        self.messageHandler = messageHandler
        webView.configuration.userContentController.add(
            messageHandler,
            name: "flutterLive2D")
        addSubview(webView)
        Live2DLog.write(viewId: viewId, "view created; starting local resource server")
        server.start { [weak self] result in
            switch result {
            case .success(let baseURL):
                Live2DLog.write(viewId: viewId, "resource server ready at \(baseURL.absoluteString)")
                self?.loadRuntimePage(baseURL: baseURL)
            case .failure(let error):
                Live2DLog.write(viewId: viewId, "resource server failed: \(error.localizedDescription)")
                self?.failLoading(error)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.isReady, self.loadError == nil else { return }
            let message = "JavaScript runtime initialization timed out after 30s. " +
                "core=\(cubismCoreURL), \(self.server.diagnostics)"
            Live2DLog.write(viewId: self.viewId, message)
            self.failLoading(Live2DError(message))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        Live2DLog.write(viewId: viewId, "view disposing")
        server.stop()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "flutterLive2D")
        for command in pendingCommands.values {
            command.completion(.failure(Live2DError("Live2D view was disposed.")))
        }
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func loadModel(
        modelDir: String,
        fileName: String,
        completion: @escaping Live2DCommandCompletion
    ) {
        let directory = URL(fileURLWithPath: modelDir, isDirectory: true)
        let modelURL = directory.appendingPathComponent(fileName).standardizedFileURL
        Live2DLog.write(
            viewId: viewId,
            "loadModel requested file=\(modelURL.path)")
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            Live2DLog.write(viewId: viewId, "loadModel rejected: model file not found")
            completion(.failure(Live2DError("Model file not found: \(modelURL.path)")))
            return
        }
        server.setModelRoot(directory)
        Live2DLog.write(viewId: viewId, "model resource root=\(directory.path)")
        whenReady { [weak self] in
            guard let self, let baseURL = self.server.baseURL else {
                completion(.failure(Live2DError("Local resource server is unavailable.")))
                return
            }
            self.execute(
                "loadModel",
                arguments: [baseURL.appendingPathComponent("model/").absoluteString, fileName],
                completion: completion)
        } onError: { error in
            completion(.failure(error))
        }
    }

    func command(
        _ name: String,
        arguments: [Any],
        completion: @escaping Live2DCommandCompletion
    ) {
        whenReady { [weak self] in
            guard let self else {
                completion(.failure(Live2DError("Live2D view was disposed.")))
                return
            }
            self.execute(name, arguments: arguments, completion: completion)
        } onError: { error in
            completion(.failure(error))
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }
        if type == "ready" {
            Live2DLog.write(viewId: viewId, "JavaScript runtime ready")
            isReady = true
            let operations = readyOperations
            readyOperations.removeAll()
            operations.forEach { $0.success() }
            return
        }
        if type == "loadError" {
            Live2DLog.write(
                viewId: viewId,
                "JavaScript runtime failed: \(body["error"] as? String ?? "unknown error")")
            failLoading(Live2DError(
                body["error"] as? String ?? "Failed to initialize Live2D runtime."))
            return
        }
        if type == "console" {
            let level = body["level"] as? String ?? "log"
            let text = body["message"] as? String ?? ""
            Live2DLog.write(viewId: viewId, "JS \(level): \(text)")
            return
        }
        guard type == "result", let id = body["id"] as? String,
              let command = pendingCommands.removeValue(forKey: id) else {
            if type == "result" {
                Live2DLog.write(viewId: viewId, "late/unknown JavaScript result id=\(body["id"] ?? "nil")")
            }
            return
        }
        let elapsed = Date().timeIntervalSince(command.startedAt)
        if (body["ok"] as? Bool) == true {
            let value = body["value"]
            Live2DLog.write(
                viewId: viewId,
                String(format: "command %@ completed in %.3fs", command.name, elapsed))
            command.completion(.success(value is NSNull ? nil : value))
        } else {
            let message = body["error"] as? String ?? "Unknown JavaScript error."
            Live2DLog.write(
                viewId: viewId,
                String(format: "command %@ failed in %.3fs: %@", command.name, elapsed, message))
            command.completion(.failure(Live2DError(message)))
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Live2DLog.write(viewId: viewId, "navigation failed: \(error.localizedDescription)")
        failLoading(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Live2DLog.write(
            viewId: viewId,
            "provisional navigation failed: \(error.localizedDescription)")
        failLoading(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Live2DLog.write(viewId: viewId, "runtime page navigation finished")
    }

    private func loadRuntimePage(baseURL: URL) {
        guard let runtimeURL = server.runtimeURL,
              let runtimeSource = try? String(contentsOf: runtimeURL, encoding: .utf8) else {
            Live2DLog.write(viewId: viewId, "bundled JavaScript runtime not found")
            failLoading(Live2DError("Could not locate the bundled Live2D runtime."))
            return
        }
        Live2DLog.write(
            viewId: viewId,
            "loading runtime page bundle=\(runtimeURL.path) bytes=\(runtimeSource.utf8.count)")
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <style>
            html,body,canvas { width:100%; height:100%; margin:0; overflow:hidden; background:transparent; }
            canvas { display:block; }
          </style>
          <script>
            (() => {
              for (const level of ['debug', 'info', 'log', 'warn', 'error']) {
                const original = console[level].bind(console);
                console[level] = (...args) => {
                  original(...args);
                  try {
                    const message = args.map(value => {
                      if (typeof value === 'string') return value;
                      try { return JSON.stringify(value); } catch (_) { return String(value); }
                    }).join(' ');
                    window.webkit.messageHandlers.flutterLive2D.postMessage({
                      type:'console', level, message
                    });
                  } catch (_) {}
                };
              }
              window.addEventListener('unhandledrejection', event => {
                console.error('Unhandled promise rejection', event.reason);
              });
              window.addEventListener('error', event => {
                console.error('Window error', event.message, event.filename, event.lineno);
              });
            })();
          </script>
          <script src="\(cubismCoreURL)"
                  onload="console.info('Cubism Core downloaded')"
                  onerror="console.error('Cubism Core download failed')"></script>
          <script>\(runtimeSource)</script>
        </head>
        <body>
          <canvas id="live2d"></canvas>
          <script>
            (async () => {
              try {
                await window.FlutterLive2DWeb.createView(
                  \(viewId),
                  document.getElementById('live2d'),
                  '\(baseURL.appendingPathComponent("runtime/shaders/").absoluteString)');
                window.webkit.messageHandlers.flutterLive2D.postMessage({type:'ready'});
              } catch (error) {
                window.webkit.messageHandlers.flutterLive2D.postMessage({
                  type:'loadError',
                  error:String(error && error.message || error) + '\\n' +
                    String(error && error.stack || '') +
                    ' core=' + typeof window.Live2DCubismCore +
                    ' runtime=' + typeof window.FlutterLive2DWeb
                });
              }
            })();
          </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: baseURL.appendingPathComponent("page/"))
    }

    private func whenReady(
        _ operation: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        if let loadError {
            onError(loadError)
        } else if isReady {
            operation()
        } else {
            readyOperations.append(ReadyOperation(success: operation, failure: onError))
        }
    }

    private func execute(
        _ name: String,
        arguments: [Any],
        completion: @escaping Live2DCommandCompletion
    ) {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let argumentsJSON = String(data: data, encoding: .utf8) else {
            completion(.failure(Live2DError("Could not encode command arguments.")))
            return
        }

        let id = UUID().uuidString
        let startedAt = Date()
        pendingCommands[id] = PendingCommand(
            name: name,
            startedAt: startedAt,
            completion: completion)
        Live2DLog.write(viewId: viewId, "command \(name) dispatched id=\(id)")
        let timeout: TimeInterval = name == "loadModel" ? 75 : 15
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self,
                  let command = self.pendingCommands.removeValue(forKey: id) else {
                return
            }
            let diagnostics = self.server.diagnostics
            let message = "Command \(name) timed out after \(Int(timeout))s. \(diagnostics)"
            Live2DLog.write(viewId: self.viewId, message)
            command.completion(.failure(Live2DError(message)))
        }
        let script = """
        (async () => {
          try {
            const value = await window.FlutterLive2DWeb[\(javaScriptString(name))](
              \(viewId), ...\(argumentsJSON));
            window.webkit.messageHandlers.flutterLive2D.postMessage({
              type:'result', id:\(javaScriptString(id)), ok:true, value:value ?? null
            });
          } catch (error) {
            window.webkit.messageHandlers.flutterLive2D.postMessage({
              type:'result', id:\(javaScriptString(id)), ok:false,
              error:String(error && error.message || error) + '\\n' +
                String(error && error.stack || '')
            });
          }
        })();
        null;
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, let error,
                  let command = self.pendingCommands.removeValue(forKey: id) else {
                return
            }
            Live2DLog.write(
                viewId: self.viewId,
                "command \(name) injection failed: \(error.localizedDescription)")
            command.completion(.failure(error))
        }
    }

    private func failLoading(_ error: Error) {
        guard loadError == nil else { return }
        Live2DLog.write(viewId: viewId, "runtime unavailable: \(error.localizedDescription)")
        loadError = error
        let operations = readyOperations
        readyOperations.removeAll()
        operations.forEach { $0.failure(error) }
    }
}

private struct ReadyOperation {
    let success: () -> Void
    let failure: (Error) -> Void
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

private final class Live2DLocalServer {
    private let viewId: Int64
    private let assetRoot: URL?
    private let lock = NSLock()
    private var modelRoot: URL?
    private var listener: NWListener?
    private var readyBaseURL: URL?
    private var requestCount = 0
    private var lastRequest = "none"
    private let queue = DispatchQueue(label: "flutter_live2d.http")

    init(viewId: Int64, assetRoot: URL?) {
        self.viewId = viewId
        self.assetRoot = assetRoot?.standardizedFileURL
    }

    var runtimeURL: URL? {
        assetRoot?.appendingPathComponent("flutter_live2d_web.js")
    }

    var baseURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return readyBaseURL
    }

    var diagnostics: String {
        lock.lock()
        defer { lock.unlock() }
        return "HTTP requests=\(requestCount), last=\(lastRequest)"
    }

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                        DispatchQueue.main.async {
                            completion(.failure(
                                Live2DError("Could not resolve local server port.")))
                        }
                        return
                    }
                    self.lock.lock()
                    self.readyBaseURL = url
                    self.lock.unlock()
                    DispatchQueue.main.async { completion(.success(url)) }
                case .failed(let error):
                    Live2DLog.write(
                        viewId: self.viewId,
                        "resource listener failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { completion(.failure(error)) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    func stop() {
        Live2DLog.write(viewId: viewId, "resource server stopping; \(diagnostics)")
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    func setModelRoot(_ url: URL) {
        lock.lock()
        modelRoot = url.standardizedFileURL
        lock.unlock()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, data: Data())
    }

    private func receiveRequest(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var requestData = data
            if let chunk { requestData.append(chunk) }
            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: connection, requestData: requestData)
            } else if error != nil || isComplete || requestData.count >= 64 * 1024 {
                Live2DLog.write(
                    viewId: self.viewId,
                    "HTTP request header failed: \(error?.localizedDescription ?? "incomplete request")")
                self.send(status: 400, data: Data(), mimeType: "text/plain", to: connection)
            } else {
                self.receiveRequest(connection, data: requestData)
            }
        }
    }

    private func respond(to connection: NWConnection, requestData: Data) {
        let startedAt = Date()
        guard let request = String(data: requestData, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            record(path: "invalid-request", status: 400, bytes: 0, startedAt: startedAt)
            send(status: 400, data: Data(), mimeType: "text/plain", to: connection)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let url = URL(string: "http://localhost\(parts[1])") else {
            record(path: requestLine, status: 405, bytes: 0, startedAt: startedAt)
            send(status: 405, data: Data(), mimeType: "text/plain", to: connection)
            return
        }
        let requestPath = url.path
        let path = url.path.removingPercentEncoding?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let components = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard let area = components.first, let root = rootURL(for: area) else {
            record(path: requestPath, status: 404, bytes: 0, startedAt: startedAt)
            send(status: 404, data: Data(), mimeType: "text/plain", to: connection)
            return
        }
        let relativePath = components.count == 2 ? components[1] : ""
        let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(rootPath),
              let data = try? Data(contentsOf: fileURL) else {
            record(path: requestPath, status: 404, bytes: 0, startedAt: startedAt)
            send(status: 404, data: Data(), mimeType: "text/plain", to: connection)
            return
        }
        record(path: requestPath, status: 200, bytes: data.count, startedAt: startedAt)
        send(
            status: 200,
            data: data,
            mimeType: mimeType(for: fileURL.pathExtension),
            to: connection)
    }

    private func send(
        status: Int,
        data: Data,
        mimeType: String,
        to connection: NWConnection
    ) {
        let reason = status == 200 ? "OK" : "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Length: \(data.count)\r\n" +
            "Content-Type: \(mimeType)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func record(path: String, status: Int, bytes: Int, startedAt: Date) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let summary = "\(path) -> \(status), \(bytes) bytes, " +
            String(format: "%.3fs", elapsed)
        lock.lock()
        requestCount += 1
        lastRequest = summary
        lock.unlock()
        Live2DLog.write(viewId: viewId, "HTTP GET \(summary)")
    }

    private func rootURL(for area: String) -> URL? {
        if area == "runtime" { return assetRoot }
        guard area == "model" else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return modelRoot
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "js": return "text/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "vert", "frag": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

private struct Live2DError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private func javaScriptString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let encoded = String(data: data, encoding: .utf8) else {
        return "\"\""
    }
    return String(encoded.dropFirst().dropLast())
}

private func flutterAssetURL(for key: String) -> URL? {
    let candidates = [
        Bundle.main.bundleURL.appendingPathComponent(key),
        Bundle.main.url(forResource: key, withExtension: nil),
        Bundle.main.privateFrameworksURL?
            .appendingPathComponent("App.framework/Resources")
            .appendingPathComponent(key),
    ]
    return candidates.compactMap { $0 }.first {
        FileManager.default.fileExists(atPath: $0.path)
    }
}
