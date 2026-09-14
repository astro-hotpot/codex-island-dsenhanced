import AppKit
import WebKit

enum DeepSeekHistoryRange: String, CaseIterable, Identifiable {
    case today, yesterday, week, thirtyDays, month, lastMonth, total
    var id: String { rawValue }
    var pageLabel: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .week: return "近 7 天"
        case .thirtyDays: return "近 30 天"
        case .month: return "本月"
        case .lastMonth: return "上月"
        case .total: return "累计消耗"
        }
    }
}

struct DeepSeekHistory {
    let tokens: String
    let requests: String
    let cost: String
    let period: String
    let keyScope: String
    let totalCost: String?
    let totalTokens: String?
    let updatedAt: Date

    init?(payload: [String: String]) {
        guard let tokens = payload["tokens"], let requests = payload["requests"],
              let cost = payload["cost"], let period = payload["period"],
              let keyScope = payload["keyScope"],
              !period.isEmpty, !keyScope.isEmpty,
              tokens.range(of: #"^[0-9][0-9,]*$"#, options: .regularExpression) != nil,
              requests.range(of: #"^[0-9][0-9,]*$"#, options: .regularExpression) != nil,
              cost.range(of: #"^[¥$€][0-9,]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        self.totalCost = payload["totalCost"].flatMap { $0.range(of: #"^[¥$€][0-9,]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil ? $0 : nil }
        self.totalTokens = payload["totalTokens"].flatMap { $0.range(of: #"^[0-9][0-9,]*$"#, options: .regularExpression) != nil ? $0 : nil }
        self.tokens = tokens
        self.requests = requests
        self.cost = cost
        self.period = period
        self.keyScope = keyScope
        updatedAt = Date()
    }
}

@MainActor
final class DeepSeekHistoryStore: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = DeepSeekHistoryStore(slot: 0)
    static let second = DeepSeekHistoryStore(slot: 1)
    private let slot: Int
    private var rangeKey: String { slot == 0 ? "MacIsland.deepSeekHistoryRange" : "MacIsland.deepSeekHistoryRange.second" }
    private var pageRange: String { range == .total ? DeepSeekHistoryRange.month.pageLabel : range.pageLabel }

    init(slot: Int) {
        self.slot = slot
        let key = slot == 0 ? "MacIsland.deepSeekHistoryRange" : "MacIsland.deepSeekHistoryRange.second"
        self.range = DeepSeekHistoryRange(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? (slot == 0 ? .month : .total)
        super.init()
    }
    @Published private(set) var summary: DeepSeekHistory?
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    @Published var range: DeepSeekHistoryRange {
        didSet {
            guard range != oldValue else { return }
            UserDefaults.standard.set(range.rawValue, forKey: rangeKey)
            summary = nil
            loading = false
            webView?.stopLoading()
            refresh()
        }
    }
    private var generation = UUID().uuidString
    private var webView: WKWebView?
    private var window: NSWindow?
    private var timeout: Task<Void, Never>?

    func connect(showWindow: Bool = true) {
        if window == nil {
            let controller = WKUserContentController()
            controller.add(self, name: "deepseekUsage")

            let config = WKWebViewConfiguration()
            config.userContentController = controller
            config.websiteDataStore = .default()
            let web = WKWebView(frame: .zero, configuration: config)
            web.navigationDelegate = self
            webView = web
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.title = "DeepSeek · " + L10n.tr("Usage history")
            win.isReleasedWhenClosed = false
            win.contentView = web
            win.center()
            window = win
            refresh()
        }
        if showWindow {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func refresh() {
        guard !loading else { return }
        guard let webView else { connect(showWindow: false); return }
        loading = true
        generation = UUID().uuidString
        webView.configuration.userContentController.removeAllUserScripts()
        let script = Self.reader.replacingOccurrences(of: "__RANGE__", with: pageRange)
            .replacingOccurrences(of: "__GENERATION__", with: generation)
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        message = nil
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled else { return }
            self?.loading = false
            self?.message = L10n.tr("Open DeepSeek to sign in or check the usage page")
        }
        webView.load(URLRequest(url: URL(string: "https://platform.deepseek.com/usage")!))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == "platform.deepseek.com",
              let payload = message.body as? [String: String],
              payload["generation"] == generation,
              payload["period"] == pageRange,
              let result = DeepSeekHistory(payload: payload) else { return }
        summary = result
        loading = false
        self.message = nil
        timeout?.cancel()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        message = L10n.tr("Open DeepSeek to sign in or check the usage page")
        timeout?.cancel()
    }

    // Only visible aggregate values leave the embedded page; no cookies or authentication tokens are read.
    static let reader = #"""
    (() => {
      if (location.hostname !== 'platform.deepseek.com') return;
      let previous = '';
      const desiredRange = '__RANGE__';
      let pending = 0;
      let ready = false;
      let lifetimeTokens = '';
      let stablePayload = '';
      let stableSince = 0;
      const originalFetch = window.fetch.bind(window);
      window.fetch = async function(input, init) {
        const url = new URL(typeof input === 'string' ? input : input.url, location.href);
        const usageRequest = url.origin === location.origin && url.pathname.startsWith('/api/v0/usage/by_api_key/');
        if (usageRequest) pending++;
        let response;
        try { response = await originalFetch(input, init); }
        finally { if (usageRequest) pending--; }
        if (usageRequest && response.ok) { ready = true; setTimeout(read, 1000); }
        if (url.origin === location.origin && url.pathname === '/api/v0/usage/by_api_key/amount' && url.searchParams.get('start') !== '0') {
          const all = new URL(url); all.searchParams.set('start', '0');
          const req = input instanceof Request ? new Request(all.href, input) : all.href;
          originalFetch(req, init).then(r => r.json()).then(body => {
            const data = body?.data?.biz_data;
            if (Number(data?.start) !== 0 || !Array.isArray(data?.series)) return;
            let total = 0;
            for (const series of data.series) for (const bucket of series.buckets || []) {
              for (const key of ['PROMPT_CACHE_HIT_TOKEN','PROMPT_CACHE_MISS_TOKEN','RESPONSE_TOKEN']) {
                const n = bucket.usage?.[key];
                if (!Number.isSafeInteger(n) || n < 0) return;
                total += n;
              }
            }
            if (!Number.isSafeInteger(total)) return;
            lifetimeTokens = total.toLocaleString('en-US'); read();
          }).catch(() => {});
        }
        return response;
      };
      function read() {
        const main = document.querySelector('main');
        if (!main) return;
        const text = main.innerText;
        const heading = text.search(/(?:^|\n)(?:消费金额|Cost)\s*\n/);
        if (heading < 0) return;
        const summaryText = text.slice(heading).split(/消费金额[（(]|Cost[（(]|模型|Models/)[0];
        const tokens = summaryText.match(/(?:^|\n)Tokens\s*\n\s*([0-9][0-9,]*)/i);
        const requests = summaryText.match(/(?:API 请求次数|API Requests)\s*\n\s*([0-9][0-9,]*)/i);
        const cost = summaryText.match(/(?:^|\n)(?:消费金额|Cost)\s*\n\s*([¥$€][0-9,.]+)/i);
        const buttons = Array.from(main.querySelectorAll('button,[role="button"]')).map(b => b.innerText.trim());
        const period = buttons.find(t => /时间维度|Time Range|Time Period/i.test(t));
        const key = buttons.find(t => /API Key/i.test(t));
        if (!period || !key) return;
        const selectedRange = period.replace(/时间维度|Time Range|Time Period/i, '').trim();
        if (selectedRange !== desiredRange) {
          ready = false;
          const option = Array.from(document.querySelectorAll('body *'))
            .find(e => e.children.length === 0 && e.textContent.trim() === desiredRange);
          if (option) option.click();
          else {
            const button = Array.from(main.querySelectorAll('button,[role="button"]')).find(e => /时间维度|Time Range|Time Period/i.test(e.innerText));
            if (button) button.click();
          }
          return;
        }
        if (pending || !tokens || !requests || !cost) return;
        const lifetimeCost = text.match(/(?:累计消费金额|Total Spend)\s*\n\s*([¥$€][0-9,.]+)/i);
        const payload = {generation: '__GENERATION__', totalCost: lifetimeCost?.[1] || '', totalTokens: lifetimeTokens, tokens: tokens[1], requests: requests[1], cost: cost[1],
          period: period.replace(/时间维度|Time Range|Time Period/i, '').trim(),
          keyScope: key.replace(/API Key/i, '').trim()};
        const encoded = JSON.stringify(payload);
        if (encoded !== stablePayload) { stablePayload = encoded; stableSince = Date.now(); return; }
        if (Date.now() - stableSince < 1200 || encoded === previous) return;
        previous = encoded;
        window.webkit.messageHandlers.deepseekUsage.postMessage(payload);
      }
      let timer;
      function observe() {
      new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(read, 750); })
        .observe(document.documentElement, {subtree: true, childList: true, characterData: true});
      read();
      setInterval(read, 700);
      }
      if (document.documentElement) observe();
      else document.addEventListener('DOMContentLoaded', observe, {once:true});
    })();
    """#
}
