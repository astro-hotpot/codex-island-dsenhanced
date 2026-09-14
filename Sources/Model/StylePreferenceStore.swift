import Foundation

/// Generic UserDefaults-backed store for picker preferences. Holds the
/// currently-selected style of any `RawRepresentable & CaseIterable` enum,
/// plus a one-shot `hasCycledStyle` bool that drives the "⌘-click to cycle"
/// onboarding hint.
///
/// Used by `StylePref` (chart visualization) and `CostStylePref` (cost
/// view layout). Subclasses pin the generic parameter to a concrete enum
/// and provide a `static let shared` singleton.
@MainActor
class StylePreferenceStore<S: RawRepresentable & CaseIterable & Hashable>: ObservableObject
where S.RawValue == String {
    private let styleKey: String
    private let cycledKey: String

    @Published var style: S {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: styleKey) }
    }
    @Published var rightStyle: S {
        didSet { UserDefaults.standard.set(rightStyle.rawValue, forKey: styleKey + ".right") }
    }

    func style(isRight: Bool) -> S { isRight ? rightStyle : style }

    @Published var hasCycledStyle: Bool {
        didSet { UserDefaults.standard.set(hasCycledStyle, forKey: cycledKey) }
    }

    init(styleKey: String, cycledKey: String, defaultStyle: S) {
        self.styleKey = styleKey
        self.cycledKey = cycledKey
        let raw = UserDefaults.standard.string(forKey: styleKey) ?? ""
        let initialStyle = S(rawValue: raw) ?? defaultStyle
        self.style = initialStyle
        self.rightStyle = S(rawValue: UserDefaults.standard.string(forKey: styleKey + ".right") ?? "")
            ?? initialStyle
        // Demo mode keeps the ⌘-click hint visible regardless of prior session.
        self.hasCycledStyle = AppEnvironment.isDemo ? false : UserDefaults.standard.bool(forKey: cycledKey)
        UserDefaults.standard.set(self.rightStyle.rawValue, forKey: styleKey + ".right")
    }

    func cycle(isRight: Bool = false) {
        let all = Array(S.allCases)
        if let i = all.firstIndex(of: style(isRight: isRight)) {
            if isRight { rightStyle = all[(i + 1) % all.count] }
            else { style = all[(i + 1) % all.count] }
        }
        if !hasCycledStyle { hasCycledStyle = true }
    }
}
