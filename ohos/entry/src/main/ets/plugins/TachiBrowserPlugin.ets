// Lends the Tachiyomi extension host the system's web engine (ArkWeb) for the
// WebView that extensions use: the OpenHarmony counterpart of
// ext_host/flutter/ios/Classes/TachiBrowser.swift, with the same channel
// protocol (com.gallery.reader/exthost/browser). The host's commands arrive
// through Dart (lib/src/network/tachi/tachi_browser.dart) as "command"; what
// the pages do goes back as "events". The pages are Web components in the
// app's window, under its own content (TachiWebHost.ets), as the WKWebViews
// are on iOS: they run as the visible pages of a browser do, which sites
// that check for a real browser need. They keep their cookies in the
// engine's store, as the app's own web pages do, so a login made in the
// app's page holds for them too.
import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { BuilderNode, FrameNode, UIContext } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { tachiWebHost } from './TachiWebHost';

const TAG = 'TachiBrowserPlugin';
const CHANNEL = 'com.gallery.reader/exthost/browser';
const BRIDGE = '__tachiNative';

type Fields = Map<string, Object>;

/// A JSON value as the channel's codec takes it: objects as Map, arrays as Array.
function toCodec(value: Object | null | undefined): Object | null {
  if (value === null || value === undefined) {
    return null;
  }
  if (Array.isArray(value)) {
    const list: Array<Object | null> = [];
    for (const item of value as Array<Object | null>) {
      list.push(toCodec(item));
    }
    return list;
  }
  if (typeof value === 'object') {
    const map = new Map<string, Object | null>();
    const record = value as Record<string, Object | null>;
    for (const key of Object.keys(record)) {
      map.set(key, toCodec(record[key]));
    }
    return map;
  }
  return value;
}

function headersOf(headers: Array<Header> | null | undefined): Map<string, string> {
  const map = new Map<string, string>();
  if (headers) {
    for (const header of headers) {
      map.set(header.headerKey, header.headerValue);
    }
  }
  return map;
}

function isHttp(url: string): boolean {
  const lower = url.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

// ---- Cookies, as {"url", "setCookie"} (the host's CookieCodec.kt) ----

let engineReady = false;

function ensureEngine(): void {
  if (!engineReady) {
    webview.WebviewController.initializeWebEngine();
    webview.WebCookieManager.putAcceptCookieEnabled(true);
    engineReady = true;
  }
}

function storeCookies(entries: Array<Object> | null | undefined): void {
  if (!entries || entries.length == 0) {
    return;
  }
  ensureEngine();
  for (const entry of entries) {
    const fields = entry as Map<string, Object>;
    const url = fields.get('url') as string | undefined;
    const setCookie = fields.get('setCookie') as string | undefined;
    if (!url || !setCookie) {
      continue;
    }
    try {
      webview.WebCookieManager.configCookieSync(url, setCookie, false, true);
    } catch (e) {
      console.warn(`${TAG}: cookie not stored for ${url}: ${(e as Error).message}`);
    }
  }
}

/// The engine's cookies that a request to [url] would carry. The engine only
/// gives names and values, so each comes back as a session cookie of that host.
function cookiesFor(url: string): Array<Fields> {
  const out: Array<Fields> = [];
  if (!isHttp(url)) {
    return out;
  }
  ensureEngine();
  let line = '';
  try {
    line = webview.WebCookieManager.fetchCookieSync(url, false);
  } catch (e) {
    return out;
  }
  const end = url.indexOf('/', url.indexOf('://') + 3);
  const origin = end < 0 ? url : url.substring(0, end);
  for (const part of line.split(';')) {
    const pair = part.trim();
    if (pair.length == 0 || pair.indexOf('=') <= 0) {
      continue;
    }
    const entry: Fields = new Map<string, Object>();
    entry.set('url', `${origin}/`);
    entry.set('setCookie', `${pair}; Path=/`);
    out.push(entry);
  }
  return out;
}

// ---- One view of the host's ----

/// What the page's bootstrap script calls: a JavaScript interface method of
/// the host was invoked.
class TachiBridge {
  private page: TachiBrowserPage;

  constructor(page: TachiBrowserPage) {
    this.page = page;
  }

  post(message: string): void {
    this.page.onBridgeMessage(message);
  }
}

class TachiWebParams {
  page: TachiBrowserPage;
  controller: webview.WebviewController;
  bridge: TachiBridge;
  javaScript: boolean = false;
  scripts: Array<ScriptItem> = [];

  constructor(page: TachiBrowserPage, controller: webview.WebviewController, bridge: TachiBridge) {
    this.page = page;
    this.controller = controller;
    this.bridge = bridge;
  }
}

@Builder
function buildTachiWeb(params: TachiWebParams) {
  Web({ src: 'about:blank', controller: params.controller })
    .width('100%')
    .height('100%')
    .javaScriptAccess(params.javaScript)
    .domStorageAccess(true)
    .javaScriptProxy({
      object: params.bridge,
      name: BRIDGE,
      methodList: ['post'],
      controller: params.controller
    })
    .javaScriptOnDocumentStart(params.scripts)
    .onControllerAttached(() => params.page.onAttached())
    .onPageBegin((event: OnPageBeginEvent) => params.page.onPageBegin(event.url))
    .onPageEnd((event: OnPageEndEvent) => params.page.onPageEnd(event.url))
    .onErrorReceive((event: OnErrorReceiveEvent) => params.page.onError(event.request, event.error))
    .onHttpErrorReceive((event: OnHttpErrorReceiveEvent) => params.page.onHttpError(event.request, event.response))
    .onInterceptRequest((event: OnInterceptRequestEvent) => params.page.onRequest(event.request))
    .onLoadIntercept((event: OnLoadInterceptEvent) => params.page.onNavigate(event.data))
    .onConsole((event: OnConsoleEvent) => params.page.onConsole(event.message))
}

class TachiBrowserPage {
  readonly id: number;
  private plugin: TachiBrowserPlugin;
  private host: FrameNode;
  private controller: webview.WebviewController = new webview.WebviewController();
  private node: BuilderNode<[TachiWebParams]>;
  private params: TachiWebParams;
  private attached = false;
  private waiting: Array<() => void> = [];
  private interfaces = '{}';
  private userAgent: string | null = null;
  private nextDecision = 0;
  // navigations the host has not answered yet: call -> url
  private undecided = new Map<number, string>();
  // The next main-frame navigation is the host's own load, which Android does
  // not offer to shouldOverrideUrlLoading.
  private programmatic = false;
  private closed = false;

  constructor(id: number, plugin: TachiBrowserPlugin, host: FrameNode, uiContext: UIContext) {
    this.id = id;
    this.plugin = plugin;
    this.host = host;
    this.params = new TachiWebParams(this, this.controller, new TachiBridge(this));
    this.params.scripts = [this.bootstrap()];
    this.node = new BuilderNode<[TachiWebParams]>(uiContext);
    this.node.build(wrapBuilder<[TachiWebParams]>(buildTachiWeb), this.params);
    // into the window, under the app's content
    const frame = this.node.getFrameNode();
    if (frame != null) {
      host.appendChild(frame);
    }
  }

  /// Runs [action] once the controller is bound to its Web component.
  private whenAttached(action: () => void): void {
    if (this.attached) {
      action();
    } else {
      this.waiting.push(action);
    }
  }

  onAttached(): void {
    if (this.attached || this.closed) {
      return;
    }
    this.attached = true;
    // covered by the app's content, the page is still to run as a shown one
    this.controller.onActive();
    const waiting = this.waiting;
    this.waiting = [];
    for (const action of waiting) {
      action();
    }
  }

  /// Settings that come with every command: the user agent, JavaScript, and
  /// the JavaScript interfaces (which take effect from the next page, as on Android).
  configure(command: Map<string, Object>): void {
    const userAgent = (command.get('userAgent') as string | null | undefined) ?? null;
    const javaScript = (command.get('javaScript') as boolean | null | undefined) ?? false;
    const wanted = JSON.stringify(TachiBrowserPage.plain(command.get('interfaces')));
    let changed = false;
    if (javaScript != this.params.javaScript) {
      this.params.javaScript = javaScript;
      changed = true;
    }
    if (wanted != this.interfaces) {
      this.interfaces = wanted;
      this.params.scripts = [this.bootstrap()];
      changed = true;
    }
    if (changed) {
      this.node.update(this.params);
    }
    if (userAgent != this.userAgent) {
      this.userAgent = userAgent;
      this.whenAttached(() => {
        if (userAgent != null) {
          this.controller.setCustomUserAgent(userAgent);
        }
      });
    }
  }

  load(url: string, headers: Map<string, Object> | null | undefined): void {
    const list: Array<webview.WebHeader> = [];
    if (headers) {
      headers.forEach((value: Object, key: string) => {
        list.push({ headerKey: key, headerValue: `${value}` });
      });
    }
    this.whenAttached(() => {
      this.programmatic = true;
      try {
        this.controller.loadUrl(url, list);
      } catch (e) {
        this.programmatic = false;
        this.emitError(url, -12, 'Bad URL', true);
      }
    });
  }

  loadHtml(html: string, baseUrl: string | null | undefined): void {
    this.whenAttached(() => {
      this.programmatic = true;
      try {
        if (baseUrl) {
          this.controller.loadData(html, 'text/html', 'UTF-8', baseUrl);
        } else {
          this.controller.loadData(html, 'text/html', 'UTF-8');
        }
      } catch (e) {
        this.programmatic = false;
        this.emitError(baseUrl ?? '', -1, (e as Error).message, true);
      }
    });
  }

  /// evaluateJavascript's result as Android gives it: the value as JSON.
  evaluate(call: number, script: string): void {
    const wrapped = `(function () { try { var v = (0, eval)(${JSON.stringify(script)});` +
      ` var s = JSON.stringify(v === undefined ? null : v); return s === undefined ? 'null' : s; }` +
      ` catch (e) { return 'null'; } })()`;
    this.whenAttached(() => {
      this.controller.runJavaScriptExt(wrapped).then((message: webview.JsMessageExt) => {
        let value = 'null';
        if (message.getType() == webview.JsMessageType.STRING) {
          value = message.getString();
        }
        this.emitEval(call, value);
      }).catch((_: Error) => {
        this.emitEval(call, 'null');
      });
    });
  }

  private emitEval(call: number, value: string): void {
    const fields: Fields = new Map<string, Object>();
    fields.set('call', call);
    fields.set('value', value);
    this.emit('eval', fields);
  }

  stop(): void {
    this.whenAttached(() => this.controller.stop());
  }

  /// The host's answer to a "navigate" event. The engine has to be answered
  /// at once, so the navigation was let through when it was reported; a
  /// refusal stops the load if the page is still on its way there.
  decide(call: number, allow: boolean): void {
    const url = this.undecided.get(call);
    this.undecided.delete(call);
    if (!allow && url !== undefined && this.attached) {
      this.controller.stop();
    }
  }

  close(): void {
    this.closed = true;
    this.waiting = [];
    this.undecided.clear();
    if (this.attached) {
      try {
        this.controller.stop();
        this.controller.onInactive();
      } catch (e) {
        // the component may already be gone
      }
    }
    const frame = this.node.getFrameNode();
    if (frame != null) {
      this.host.removeChild(frame);
    }
    this.node.dispose();
  }

  // ---- what the Web component reports ----

  onPageBegin(url: string): void {
    const fields: Fields = new Map<string, Object>();
    fields.set('url', url);
    this.emit('started', fields);
  }

  onPageEnd(url: string): void {
    let title = '';
    try {
      title = this.controller.getTitle();
    } catch (e) {
      // no title yet
    }
    // The page's cookies go to the host with the event that says it finished.
    const fields: Fields = new Map<string, Object>();
    fields.set('url', url);
    fields.set('title', title);
    fields.set('cookies', cookiesFor(url));
    this.emit('finished', fields);
  }

  onError(request: WebResourceRequest, error: WebResourceError): void {
    const code = error.getErrorCode();
    // A load replaced by another or stopped: Android reports neither.
    if (code == -3) {
      return;
    }
    this.emitError(request.getRequestUrl(), TachiBrowserPage.androidCode(code), error.getErrorInfo(),
      request.isMainFrame());
  }

  private emitError(url: string, code: number, description: string, mainFrame: boolean): void {
    const fields: Fields = new Map<string, Object>();
    fields.set('url', url);
    fields.set('code', code);
    fields.set('description', description);
    fields.set('mainFrame', mainFrame);
    this.emit('error', fields);
  }

  onHttpError(request: WebResourceRequest, response: WebResourceResponse): void {
    const status = response.getResponseCode();
    if (status < 400) {
      return;
    }
    const fields: Fields = new Map<string, Object>();
    fields.set('url', request.getRequestUrl());
    fields.set('status', status);
    fields.set('reason', response.getReasonMessage());
    fields.set('headers', headersOf(response.getResponseHeader()));
    fields.set('mainFrame', request.isMainFrame());
    this.emit('httpError', fields);
  }

  /// Every request of the page, as Android's shouldInterceptRequest sees
  /// them. Observed only: nothing is answered in the engine's place.
  onRequest(request: WebResourceRequest): WebResourceResponse | null {
    const url = request.getRequestUrl();
    if (isHttp(url)) {
      this.emit('request', TachiBrowserPage.requestFields(request));
    }
    return null;
  }

  /// A navigation of the main frame other than the host's own load.
  /// Returns whether the engine should drop it: never, see [decide].
  onNavigate(request: WebResourceRequest): boolean {
    if (!request.isMainFrame()) {
      return false;
    }
    if (this.programmatic) {
      this.programmatic = false;
      return false;
    }
    this.nextDecision += 1;
    const call = this.nextDecision;
    this.undecided.set(call, request.getRequestUrl());
    const fields = TachiBrowserPage.requestFields(request);
    fields.set('call', call);
    fields.set('gesture', request.isRequestGesture());
    this.emit('navigate', fields);
    setTimeout(() => {
      this.undecided.delete(call);
    }, 5000);
    return false;
  }

  onConsole(message: ConsoleMessage): boolean {
    const fields: Fields = new Map<string, Object>();
    fields.set('message', message.getMessage());
    fields.set('source', message.getSourceId());
    this.emit('console', fields);
    return false;
  }

  /// A JavaScript interface of the host was called in the page:
  /// {"interface", "method", "args"} as JSON.
  onBridgeMessage(message: string): void {
    try {
      const parsed = toCodec(JSON.parse(message) as Object) as Fields;
      this.emit('js', parsed);
    } catch (e) {
      console.warn(`${TAG}: unreadable message from the page`);
    }
  }

  private emit(type: string, fields: Fields): void {
    if (this.closed) {
      return;
    }
    fields.set('type', type);
    fields.set('view', this.id);
    this.plugin.emit(fields);
  }

  private static requestFields(request: WebResourceRequest): Fields {
    const fields: Fields = new Map<string, Object>();
    fields.set('url', request.getRequestUrl());
    fields.set('method', request.getRequestMethod());
    fields.set('headers', headersOf(request.getRequestHeader()));
    fields.set('mainFrame', request.isMainFrame());
    return fields;
  }

  /// A codec value (Map, Array) as a plain JSON value.
  private static plain(value: Object | null | undefined): Object | null {
    if (value === null || value === undefined) {
      return null;
    }
    if (value instanceof Map) {
      const record: Record<string, Object | null> = {};
      (value as Map<string, Object>).forEach((item: Object, key: string) => {
        record[key] = TachiBrowserPage.plain(item);
      });
      return record;
    }
    if (Array.isArray(value)) {
      const list: Array<Object | null> = [];
      for (const item of value as Array<Object>) {
        list.push(TachiBrowserPage.plain(item));
      }
      return list;
    }
    return value;
  }

  /// WebViewClient's ERROR_* for one of the engine's network errors.
  private static androidCode(code: number): number {
    switch (code) {
      case -105: // name not resolved
      case -137:
        return -2;
      case -102: // connection refused
      case -101:
      case -104:
      case -106:
      case -109:
        return -6;
      case -7: // timed out
      case -118:
        return -8;
      case -310: // too many redirects
        return -9;
      case -301: // unknown URL scheme
      case -302:
        return -10;
      case -300: // invalid URL
        return -12;
      default:
        // the engine's certificate and TLS errors
        return (code <= -107 && code >= -117) || (code <= -200 && code >= -219) ? -11 : -1;
    }
  }

  /// Runs before each document's own scripts: defines the host's JavaScript
  /// interfaces, whose calls are posted to the host. The page's requests and
  /// console output are reported by the engine itself.
  private bootstrap(): ScriptItem {
    const script = `(function () {
  if (window.__tachiBridge) return;
  window.__tachiBridge = true;
  var native = window.${BRIDGE};
  if (!native) return;
  var interfaces = ${this.interfaces} || {};
  Object.keys(interfaces).forEach(function (name) {
    var target = {};
    interfaces[name].forEach(function (method) {
      target[method] = function () {
        var args = Array.prototype.slice.call(arguments).map(function (a) { return a === undefined ? null : a; });
        try { native.post(JSON.stringify({ interface: name, method: method, args: args })); } catch (e) {}
      };
    });
    window[name] = target;
  });
})();`;
    return { script: script, scriptRules: ['*'] };
  }
}

export default class TachiBrowserPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private pages = new Map<number, TachiBrowserPage>();
  // commands are applied in order, also while the first one waits for the window
  private queue: Promise<void> = Promise.resolve();

  getUniqueClassName(): string {
    return TAG;
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.pages.forEach((page: TachiBrowserPage) => page.close());
    this.pages.clear();
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
  }

  onDetachedFromAbility(): void {
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    try {
      const args = (call.args as Map<string, Object> | null) ?? new Map<string, Object>();
      if (call.method === 'command') {
        this.queue = this.queue.then(() => this.apply(args)).catch((e: Error) => {
          console.warn(`${TAG}: command failed: ${e.message}`);
        });
        result.success(null);
      } else if (call.method === 'setCookies') {
        storeCookies(args.get('cookies') as Array<Object> | undefined);
        result.success(null);
      } else if (call.method === 'cookies') {
        const out: Array<Fields> = [];
        const urls = (args.get('urls') as Array<string> | undefined) ?? [];
        for (const url of urls) {
          for (const entry of cookiesFor(url)) {
            out.push(entry);
          }
        }
        result.success(out);
      } else {
        result.notImplemented();
      }
    } catch (e) {
      result.error('browser', `${call.method}: ${(e as Error).message}`, null);
    }
  }

  emit(event: Fields): void {
    const events: Array<Fields> = [event];
    this.channel?.invokeMethod('events', events);
  }

  private async apply(command: Map<string, Object>): Promise<void> {
    const op = command.get('op') as string | undefined;
    const view = command.get('view') as number | undefined;
    if (op === undefined || view === undefined) {
      return;
    }
    if (op === 'destroy') {
      this.pages.get(view)?.close();
      this.pages.delete(view);
      return;
    }
    let page = this.pages.get(view);
    if (page === undefined) {
      ensureEngine();
      const host = await tachiWebHost.ready();
      const uiContext = tachiWebHost.uiContext();
      if (uiContext == null) {
        throw new Error('the page has no UI context');
      }
      page = new TachiBrowserPage(view, this, host, uiContext);
      this.pages.set(view, page);
    }
    page.configure(command);
    const cookies = command.get('cookies') as Array<Object> | undefined;
    switch (op) {
      case 'load':
        storeCookies(cookies);
        page.load((command.get('url') as string | undefined) ?? '', command.get('headers') as Map<string, Object> | undefined);
        break;
      case 'loadHtml':
        storeCookies(cookies);
        page.loadHtml((command.get('html') as string | undefined) ?? '', command.get('baseUrl') as string | undefined);
        break;
      case 'eval':
        page.evaluate((command.get('call') as number | undefined) ?? 0, (command.get('script') as string | undefined) ?? '');
        break;
      case 'stop':
        page.stop();
        break;
      case 'decide':
        page.decide((command.get('call') as number | undefined) ?? 0, (command.get('allow') as boolean | undefined) ?? true);
        break;
      default:
        break;
    }
  }
}
