#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import FlutterMacOS
import AppKit
#endif
import WebKit

/// Lends the extension host this platform's WKWebView for the WebView that
/// extensions use (ext_host's compat android.webkit.WebView and
/// BrowserRelay.kt). The host's commands arrive through Dart
/// (lib/src/network/tachi/tachi_browser.dart) as "command"; what the pages do
/// goes back as "events". The views keep their cookies in the default
/// website data store, as the app's own web pages do, so a login made in the
/// app's page holds for them too. The same file serves iOS and macOS.
final class TachiBrowser: NSObject {
  private static var instance: TachiBrowser?

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "com.gallery.reader/exthost/browser", binaryMessenger: messenger)
    let browser = TachiBrowser(channel: channel)
    channel.setMethodCallHandler { call, result in browser.handle(call, result: result) }
    instance = browser
  }

  private let channel: FlutterMethodChannel
  private var pages: [Int: TachiBrowserPage] = [:]

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "command":
      apply(arguments)
      result(nil)
    case "setCookies":
      TachiBrowser.store(arguments["cookies"] as? [[String: Any]] ?? []) { result(nil) }
    case "cookies":
      let urls = (arguments["urls"] as? [String] ?? []).compactMap(URL.init(string:))
      TachiBrowser.cookies(for: urls) { result($0) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  fileprivate func emit(_ event: [String: Any]) {
    channel.invokeMethod("events", arguments: [event])
  }

  private func apply(_ command: [String: Any]) {
    guard let op = command["op"] as? String, let id = (command["view"] as? NSNumber)?.intValue else { return }
    if op == "destroy" {
      pages.removeValue(forKey: id)?.close()
      return
    }
    let page: TachiBrowserPage
    if let existing = pages[id] {
      page = existing
    } else {
      page = TachiBrowserPage(id: id, browser: self)
      pages[id] = page
    }
    page.configure(command)
    let cookies = command["cookies"] as? [[String: Any]] ?? []
    switch op {
    case "load":
      let url = command["url"] as? String ?? ""
      let headers = command["headers"] as? [String: String] ?? [:]
      TachiBrowser.store(cookies) { page.load(url, headers: headers) }
    case "loadHtml":
      let baseURL = (command["baseUrl"] as? String).flatMap(URL.init(string:))
      let html = command["html"] as? String ?? ""
      TachiBrowser.store(cookies) { page.loadHtml(html, baseURL: baseURL) }
    case "eval":
      page.evaluate(call: (command["call"] as? NSNumber)?.intValue ?? 0, script: command["script"] as? String ?? "")
    case "stop":
      page.webView.stopLoading()
    case "decide":
      page.decide(call: (command["call"] as? NSNumber)?.intValue ?? 0, allow: command["allow"] as? Bool ?? true)
    default:
      break
    }
  }

  // MARK: Cookies, as {"url", "setCookie"} (the host's CookieCodec.kt)

  private static var cookieStore: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

  static func store(_ entries: [[String: Any]], then done: @escaping () -> Void) {
    let cookies = entries.compactMap(cookie(from:))
    if cookies.isEmpty {
      done()
      return
    }
    let group = DispatchGroup()
    for cookie in cookies {
      group.enter()
      cookieStore.setCookie(cookie) { group.leave() }
    }
    group.notify(queue: .main, execute: done)
  }

  /// The cookies of the store that the hosts of [urls] and their parent domains hold.
  static func cookies(for urls: [URL], then done: @escaping ([[String: Any]]) -> Void) {
    let hosts = Set(urls.compactMap { $0.host?.lowercased() })
    if hosts.isEmpty {
      done([])
      return
    }
    cookieStore.getAllCookies { all in
      let matching = all.filter { cookie in
        let domain = cookie.domain.lowercased().hasPrefix(".") ? String(cookie.domain.lowercased().dropFirst()) : cookie.domain.lowercased()
        return hosts.contains { $0 == domain || $0.hasSuffix("." + domain) }
      }
      done(matching.map(entry(of:)))
    }
  }

  private static func cookie(from entry: [String: Any]) -> HTTPCookie? {
    guard let header = entry["setCookie"] as? String, let url = (entry["url"] as? String).flatMap(URL.init(string:)) else { return nil }
    return HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url).first
  }

  private static func entry(of cookie: HTTPCookie) -> [String: Any] {
    let domainCookie = cookie.domain.hasPrefix(".")
    let host = domainCookie ? String(cookie.domain.dropFirst()) : cookie.domain
    var header = "\(cookie.name)=\(cookie.value); Path=\(cookie.path)"
    if domainCookie { header += "; Domain=\(host)" }
    if let expires = cookie.expiresDate { header += "; Expires=\(httpDate.string(from: expires))" }
    if cookie.isSecure { header += "; Secure" }
    if cookie.isHTTPOnly { header += "; HttpOnly" }
    return ["url": "\(cookie.isSecure ? "https" : "http")://\(host)\(cookie.path)", "setCookie": header]
  }

  private static let httpDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter
  }()
}

/// One view of the host's: a WKWebView kept out of sight in the app's window,
/// where pages run as in a visible one.
private final class TachiBrowserPage: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let id: Int
  let webView: WKWebView
  private weak var browser: TachiBrowser?
  private var interfaces: [String: [String]] = [:]
  private var decisions: [Int: (WKNavigationActionPolicy) -> Void] = [:]
  private var nextDecision = 0
  /// The next main-frame navigation is the host's own load, which Android does
  /// not offer to shouldOverrideUrlLoading.
  private var programmatic = false

  init(id: Int, browser: TachiBrowser) {
    self.id = id
    self.browser = browser
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    webView = HiddenWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: configuration)
    super.init()
    webView.configuration.userContentController.add(WeakMessageHandler(self), name: "tachi")
    webView.navigationDelegate = self
    install()
    attach()
  }

  /// Settings that come with every command: the user agent, JavaScript, and
  /// the JavaScript interfaces (which take effect from the next page, as on Android).
  func configure(_ command: [String: Any]) {
    let userAgent = command["userAgent"] as? String
    if webView.customUserAgent != userAgent { webView.customUserAgent = userAgent }
    let javaScript = command["javaScript"] as? Bool ?? false
    if #available(iOS 14.0, macOS 11.0, *) {
      webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScript
    } else {
      webView.configuration.preferences.javaScriptEnabled = javaScript
    }
    let wanted = command["interfaces"] as? [String: [String]] ?? [:]
    if wanted != interfaces {
      interfaces = wanted
      install()
    }
  }

  func load(_ address: String, headers: [String: String]) {
    guard let url = URL(string: address) else {
      emit("error", ["url": address, "code": -12, "description": "Bad URL", "mainFrame": true])
      return
    }
    var request = URLRequest(url: url)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    programmatic = true
    webView.load(request)
  }

  func loadHtml(_ html: String, baseURL: URL?) {
    programmatic = true
    webView.loadHTMLString(html, baseURL: baseURL)
  }

  func evaluate(call: Int, script: String) {
    webView.evaluateJavaScript(script) { [weak self] value, error in
      self?.emit("eval", ["call": call, "value": error == nil ? TachiBrowserPage.json(value) : "null"])
    }
  }

  func decide(call: Int, allow: Bool) {
    decisions.removeValue(forKey: call)?(allow ? .allow : .cancel)
  }

  func close() {
    for decide in decisions.values { decide(.cancel) }
    decisions.removeAll()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "tachi")
    webView.removeFromSuperview()
  }

  private func emit(_ type: String, _ fields: [String: Any] = [:]) {
    var event = fields
    event["type"] = type
    event["view"] = id
    browser?.emit(event)
  }

  /// Behind the app's own view (iOS) or transparent and not taking clicks
  /// (macOS): in a window, so the page is not throttled as a detached one may be.
  private func attach() {
    #if os(iOS)
    webView.isUserInteractionEnabled = false
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    if let window = windows.first(where: \.isKeyWindow) ?? windows.first {
      webView.frame = window.bounds
      window.insertSubview(webView, at: 0)
    }
    #else
    webView.alphaValue = 0
    if let content = (NSApp.mainWindow ?? NSApp.windows.first)?.contentView {
      webView.frame = content.bounds
      content.addSubview(webView, positioned: .below, relativeTo: nil)
    }
    #endif
  }

  private func install() {
    let controller = webView.configuration.userContentController
    controller.removeAllUserScripts()
    controller.addUserScript(WKUserScript(source: TachiBrowserPage.bootstrap(interfaces), injectionTime: .atDocumentStart, forMainFrameOnly: false))
  }

  // MARK: WKNavigationDelegate

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let mainFrame = action.targetFrame?.isMainFrame ?? true
    guard let url = action.request.url else {
      decisionHandler(.allow)
      return
    }
    let request: [String: Any] = [
      "url": url.absoluteString,
      "method": action.request.httpMethod ?? "GET",
      "headers": action.request.allHTTPHeaderFields ?? [:],
      "mainFrame": mainFrame,
    ]
    if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { emit("request", request) }
    if !mainFrame || programmatic {
      if mainFrame { programmatic = false }
      decisionHandler(.allow)
      return
    }
    nextDecision += 1
    let call = nextDecision
    decisions[call] = decisionHandler
    var fields = request
    fields["call"] = call
    fields["gesture"] = action.navigationType == .linkActivated
    emit("navigate", fields)
    // The host answers within milliseconds; a page is not held up by one that does not.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      self?.decisions.removeValue(forKey: call)?(.allow)
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
      var headers: [String: String] = [:]
      for (name, value) in http.allHeaderFields { headers["\(name)"] = "\(value)" }
      emit("httpError", [
        "url": http.url?.absoluteString ?? "",
        "status": http.statusCode,
        "reason": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
        "headers": headers,
        "mainFrame": response.isForMainFrame,
      ])
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    emit("started", ["url": webView.url?.absoluteString ?? ""])
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let url = webView.url
    let title = webView.title ?? ""
    // The page's cookies go to the host before it hears the page finished.
    TachiBrowser.cookies(for: url.map { [$0] } ?? []) { [weak self] cookies in
      self?.emit("finished", ["url": url?.absoluteString ?? "", "title": title, "cookies": cookies])
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    fail(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    fail(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    emit("error", ["url": webView.url?.absoluteString ?? "", "code": -1, "description": "The page's process ended", "mainFrame": true])
  }

  private func fail(_ error: Error) {
    let error = error as NSError
    // A load replaced by another, or stopped by a navigation decision: Android reports neither.
    if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
    if error.domain == "WebKitErrorDomain" && error.code == 102 { return }
    let url = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? webView.url?.absoluteString ?? ""
    emit("error", ["url": url, "code": TachiBrowserPage.androidCode(error), "description": error.localizedDescription, "mainFrame": true])
  }

  /// WebViewClient's ERROR_* for a loading error.
  private static func androidCode(_ error: NSError) -> Int {
    guard error.domain == NSURLErrorDomain else { return -1 }
    switch error.code {
    case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return -2
    case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet: return -6
    case NSURLErrorTimedOut: return -8
    case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation: return -9
    case NSURLErrorUnsupportedURL: return -10
    case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
         NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected:
      return -11
    case NSURLErrorBadURL: return -12
    default: return -1
    }
  }

  // MARK: WKScriptMessageHandler: what the bootstrap script reports

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard var body = message.body as? [String: Any], let type = body["type"] as? String, ["request", "js", "console"].contains(type) else { return }
    body.removeValue(forKey: "type")
    switch type {
    case "request": body["mainFrame"] = false
    case "console": body["source"] = message.frameInfo.request.url?.absoluteString ?? ""
    default: break
    }
    emit(type, body)
  }

  /// evaluateJavascript's result as Android gives it: the value as JSON.
  private static func json(_ value: Any?) -> String {
    guard let value = value, !(value is NSNull) else { return "null" }
    var options: JSONSerialization.WritingOptions = [.fragmentsAllowed]
    if #available(iOS 13.0, macOS 10.15, *) { options.insert(.withoutEscapingSlashes) }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }

  /// Runs before each document's own scripts: reports the page's requests
  /// (XMLHttpRequest and fetch) and console output, and defines the host's
  /// JavaScript interfaces, whose calls are posted to the host.
  private static func bootstrap(_ interfaces: [String: [String]]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: interfaces)) ?? Data("{}".utf8)
    let names = String(data: data, encoding: .utf8) ?? "{}"
    return """
    (function () {
      if (window.__tachiBridge) return;
      window.__tachiBridge = true;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tachi;
      if (!handler) return;
      function post(message) { try { handler.postMessage(message); } catch (e) {} }
      function absolute(url) { try { return new URL(url, location.href).href; } catch (e) { return String(url); } }
      function headersOf(value) {
        var out = {};
        try { new Headers(value || {}).forEach(function (v, k) { out[k] = v; }); } catch (e) {}
        return out;
      }
      var open = XMLHttpRequest.prototype.open;
      var setHeader = XMLHttpRequest.prototype.setRequestHeader;
      var send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__tachi = { method: String(method || 'GET').toUpperCase(), url: absolute(url), headers: {} };
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        if (this.__tachi) this.__tachi.headers[name] = String(value);
        return setHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        if (this.__tachi) post({ type: 'request', url: this.__tachi.url, method: this.__tachi.method, headers: this.__tachi.headers });
        return send.apply(this, arguments);
      };
      if (window.fetch) {
        var fetch = window.fetch;
        window.fetch = function (input, init) {
          try {
            var request = input instanceof Request ? input : null;
            var headers = headersOf(request ? request.headers : null);
            var extra = headersOf(init && init.headers);
            for (var name in extra) headers[name] = extra[name];
            var method = (init && init.method) || (request && request.method) || 'GET';
            post({ type: 'request', url: absolute(request ? request.url : input), method: String(method).toUpperCase(), headers: headers });
          } catch (e) {}
          return fetch.apply(this, arguments);
        };
      }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          try { post({ type: 'console', message: Array.prototype.map.call(arguments, String).join(' ') }); } catch (e) {}
          return original.apply(console, arguments);
        };
      });
      var interfaces = \(names);
      Object.keys(interfaces).forEach(function (name) {
        var target = {};
        interfaces[name].forEach(function (method) {
          target[method] = function () {
            var args = Array.prototype.slice.call(arguments).map(function (a) { return a === undefined ? null : a; });
            post({ type: 'js', interface: name, method: method, args: args });
          };
        });
        window[name] = target;
      });
    })();
    """
  }
}

private final class HiddenWebView: WKWebView {
  #if os(macOS)
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  #endif
}

/// WKUserContentController keeps its handlers; this one does not keep the page.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?

  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(controller, didReceive: message)
  }
}
