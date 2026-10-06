import SwiftUI
import Loopl
import LooplUI

/// Observable face of `HFAccount.shared` for the UI: who is signed in (cached identity so the row
/// renders offline), verifying state, last error. One instance per app (`Engine.hf`).
@MainActor @Observable
public final class HFSession {
    public private(set) var identity: HFAccount.Identity?
    public private(set) var verifying = false
    public private(set) var error: String?
    private let account: HFAccount
    private static let identityKey = "loopl.hf.identity"

    public init(account: HFAccount = .shared) {
        self.account = account
        guard account.isSignedIn else { return }
        if let d = UserDefaults.standard.data(forKey: Self.identityKey), let who = try? JSONDecoder().decode(HFAccount.Identity.self, from: d) {
            identity = who
        } else {
            // A token without a cached identity (signed in by the self-test harness, or the cache was cleared): ask once.
            Task { await refresh() }
        }
    }

    public var isSignedIn: Bool { account.isSignedIn }
    public var token: String? { account.token }
    public var provider: HFTokenProvider { account.provider }
    /// The author whose repos "Mine" lists.
    public var author: String? { identity?.name }

    /// Paste → whoami → Keychain. Returns true when the token was accepted.
    @discardableResult
    public func signIn(_ raw: String) async -> Bool {
        verifying = true; error = nil
        defer { verifying = false }
        do {
            let who = try await account.signIn(raw)
            identity = who
            UserDefaults.standard.set(try? JSONEncoder().encode(who), forKey: Self.identityKey)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Re-check the stored token (e.g. revoked on huggingface.co). Network errors keep the cached identity.
    public func refresh() async {
        guard let t = account.token else { return }
        do {
            let who = try await account.whoami(t)
            identity = who
            UserDefaults.standard.set(try? JSONEncoder().encode(who), forKey: Self.identityKey)
        } catch let e as HFAccount.AccountError where e == .invalidToken {
            error = e.localizedDescription
        } catch {}
    }

    public func signOut() {
        account.signOut()
        identity = nil; error = nil
        UserDefaults.standard.removeObject(forKey: Self.identityKey)
    }
}

/// Settings › Hugging Face. Signed out: a SecureField + "Verify" (the token is checked with whoami
/// before it is kept). Signed in: avatar, name, token label, scope badges, Remove. The copy says the
/// three true things: Keychain only, sent only to huggingface.co, what it unlocks.
struct HuggingFaceSection: View {
    @Bindable var hf: HFSession
    @Bindable var settings: AppSettings
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            if let who = hf.identity {
                signedIn(who)
            } else {
                signedOut
            }
        } header: {
            Text("Hugging Face")
        } footer: {
            Text(footer)
        }
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: hf.identity)
        .animation(LooplDesign.Motion.crossfade, value: hf.verifying)
    }

    // MARK: signed out

    @ViewBuilder private var signedOut: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.horizontal").foregroundStyle(LooplDesign.accent).frame(width: 20)
            SecureField("Access token (hf_…)", text: $draft)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.go)
                .onSubmit { verify() }
                .accessibilityIdentifier("hf-token-field")
            if hf.verifying {
                PulsingMark().frame(width: 16, height: 16).transition(.opacity)
            } else {
                Button("Verify") { verify() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(LooplDesign.accent)
                    .disabled(!HFAccount.looksLikeToken(draft.trimmingCharacters(in: .whitespacesAndNewlines)) || settings.offline)
                    .accessibilityIdentifier("hf-verify")
            }
        }
        if let error = hf.error {
            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityIdentifier("hf-error")
        }
        Link(destination: URL(string: "https://huggingface.co/settings/tokens")!) {
            Label("Create a token on huggingface.co", systemImage: "safari")
        }
        .font(.footnote)
    }

    private func verify() {
        guard !hf.verifying else { return }
        let raw = draft
        focused = false
        Task {
            let ok = await hf.signIn(raw)
            LooplDesign.haptic(ok ? 1 : 0)
            if ok { draft = "" }
        }
    }

    // MARK: signed in

    @ViewBuilder private func signedIn(_ who: HFAccount.Identity) -> some View {
        HStack(spacing: 12) {
            avatar(who)
            VStack(alignment: .leading, spacing: 3) {
                Text(who.fullname?.isEmpty == false ? who.fullname! : who.name).font(.body.weight(.medium))
                Text("@\(who.name)" + (who.tokenName.map { " · token “\($0)”" } ?? "")).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hf-identity")

        HStack(spacing: 8) {
            ForEach(HFAccount.Scope.allCases, id: \.self) { scope in
                ScopeBadge(scope: scope, granted: who.scopes.contains(scope))
            }
            Spacer()
        }
        .accessibilityIdentifier("hf-scopes")

        Button(role: .destructive) {
            LooplDesign.haptic()
            hf.signOut()
        } label: { Label("Remove token", systemImage: "key.slash") }
        .accessibilityIdentifier("hf-remove")
    }

    @ViewBuilder private func avatar(_ who: HFAccount.Identity) -> some View {
        AsyncImage(url: who.avatarURL) { phase in
            if let img = phase.image { img.resizable().scaledToFill() }
            else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var footer: String {
        if let who = hf.identity {
            let missing = HFAccount.Scope.allCases.filter { !who.scopes.contains($0) }
            var s = "Stored in this device's Keychain, sent only to huggingface.co. "
            if missing.isEmpty { s += "This token can download your private models, push conversations to your datasets and start training jobs." }
            else { s += "To " + missing.map(\.needed).joined(separator: " and ") + ", create a token with " + missing.map(\.label).joined(separator: " + ") + " access." }
            return s
        }
        return "Optional. A token lets loopl download your private models, share conversations to a dataset you own and start training jobs on your account. It stays in this device's Keychain and is only ever sent to huggingface.co."
    }
}

/// read · write · jobs as a pill; granted = accent tint, missing = outlined and dimmed.
struct ScopeBadge: View {
    let scope: HFAccount.Scope
    let granted: Bool
    var body: some View {
        Label(scope.label, systemImage: granted ? "checkmark" : "minus")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(granted ? LooplDesign.accent.opacity(0.14) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(granted ? LooplDesign.accent.opacity(0.5) : Color.secondary.opacity(0.35), lineWidth: 1))
            .foregroundStyle(granted ? LooplDesign.accent : .secondary)
            .accessibilityLabel("\(scope.label) \(granted ? "granted" : "not granted")")
    }
}
