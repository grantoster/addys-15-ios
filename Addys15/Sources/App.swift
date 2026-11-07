import SwiftUI

@main
struct Addys15App: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if model.role == nil || model.code == nil {
                WelcomeView()
            } else if model.role == .addy {
                AddyHome()
            } else {
                MomHome()
            }
        }
        // While the app is open, check iCloud every 15 seconds for the other device's changes.
        .task(id: phase == .active && model.code != nil) {
            guard phase == .active, model.code != nil else { return }
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

// MARK: - First launch

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var role: Role?
    @State private var newCode = Pairing.newCode()
    @State private var typed = ""
    @State private var mode = 0 // 0 = choose, 1 = show new code, 2 = type a code

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Addy's 15%").font(.kid(44, .heavy)).foregroundStyle(Theme.purple).padding(.top, 40)
                if role == nil {
                    Text("Who's using this device?").font(.kid(26, .semibold)).foregroundStyle(Theme.ink)
                    roleCard(.addy, "I'm Addy", "Take pictures and make listings", "camera.fill")
                    roleCard(.mom, "I'm Mom", "Post to Marketplace and mark things sold", "iphone")
                } else if mode == 0 {
                    Text("Connect Addy's iPad and Mom's iPhone").font(.kid(24, .semibold)).foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    Text("Do this once. Both devices use the same code.").font(.kid(17, .bold)).foregroundStyle(Theme.muted)
                    Button("This is the first device") { mode = 1 }
                        .buttonStyle(ChunkyButtonStyle(fill: Theme.purple, shadow: Theme.purpleDark, height: 64))
                    Button("I have a code") { mode = 2 }
                        .buttonStyle(ChunkyButtonStyle(fill: Theme.yellow, shadow: Theme.yellowDark, text: Theme.ink, height: 64))
                    backButton
                } else if mode == 1 {
                    Text("Your family code").font(.kid(22, .semibold)).foregroundStyle(Theme.ink)
                    Text(Pairing.pretty(newCode)).font(.system(size: 56, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Theme.purple).textSelection(.enabled)
                        .accessibilityLabel(newCode.map(String.init).joined(separator: " "))
                    Text("On the other device, open Addy's 15%, pick who's using it, tap \"I have a code\" and type this code. It's also in Settings later.")
                        .font(.kid(17, .bold)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    Button("Done") { model.setUp(role: role!, code: newCode) }
                        .buttonStyle(ChunkyButtonStyle(fill: Theme.purple, shadow: Theme.purpleDark, height: 64))
                    backButton
                } else {
                    Text("Type the family code").font(.kid(22, .semibold)).foregroundStyle(Theme.ink)
                    TextField("ABC-DEF", text: $typed)
                        .font(.system(size: 40, weight: .heavy, design: .monospaced)).multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .frame(minHeight: 72)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.purple, lineWidth: 3))
                    Text("Find it on the other device under Settings, or on its setup screen.")
                        .font(.kid(16, .bold)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    Button("Connect") { model.setUp(role: role!, code: Pairing.normalize(typed)) }
                        .buttonStyle(ChunkyButtonStyle(fill: Theme.purple, shadow: Theme.purpleDark, height: 64))
                        .disabled(Pairing.normalize(typed).count != 6)
                    backButton
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.cream.ignoresSafeArea())
    }

    private var backButton: some View {
        Button("Back") { if mode == 0 { role = nil } else { mode = 0 } }
            .font(.kid(18, .heavy)).foregroundStyle(Theme.purple).frame(minHeight: 44)
    }

    private func roleCard(_ r: Role, _ title: String, _ subtitle: String, _ symbol: String) -> some View {
        Button { role = r } label: {
            HStack(spacing: 18) {
                Image(systemName: symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 70, height: 70).background(Circle().fill(r == .addy ? Theme.purple : Theme.green))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.kid(26, .heavy)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.kid(16, .bold)).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.purple)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color.white).shadow(color: Theme.line, radius: 0, y: 3))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings (Mom's gear button; on Addy's screens, press and hold the title for 2 seconds)

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pickup = ""
    @State private var keyText = ""
    @State private var keySaved = KeyStore.saved != nil
    @State private var newCode = ""
    @State private var confirmSwitch = false

    var body: some View {
        NavigationStack {
            Form {
                Section("This device") {
                    LabeledContent("Used by", value: model.role == .addy ? "Addy" : "Mom")
                    Button("Switch to \(model.role == .addy ? "Mom" : "Addy")") { confirmSwitch = true }
                }
                Section {
                    LabeledContent("Family code") {
                        Text(Pairing.pretty(model.code ?? "")).font(.system(.body, design: .monospaced).weight(.heavy))
                            .textSelection(.enabled)
                    }
                    ShareLink(item: "Addy's 15% family code: \(Pairing.pretty(model.code ?? ""))") { Label("Share the code", systemImage: "square.and.arrow.up") }
                    Button("Make a new code") {
                        if let r = model.role { model.setUp(role: r, code: Pairing.newCode()) }
                    }
                    TextField("Use a different code", text: $newCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    if Pairing.normalize(newCode).count == 6 {
                        Button("Connect to \(Pairing.pretty(Pairing.normalize(newCode)))") {
                            if let r = model.role { model.setUp(role: r, code: Pairing.normalize(newCode)) }
                            newCode = ""
                        }
                    }
                } header: { Text("Pairing") } footer: {
                    Text("Both devices need the same code. They sync through iCloud, so each one must be signed in to iCloud.")
                }
                Section {
                    LabeledContent("Status") {
                        Text(model.syncProblem ?? (model.lastSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet"))
                    }
                    Button(model.syncing ? "Syncing…" : "Sync now") { Task { await model.refresh() } }.disabled(model.syncing)
                } header: { Text("Sync") }

                if model.role == .mom {
                    Section {
                        TextField("Added to every description", text: $pickup, axis: .vertical)
                            .onSubmit { model.setPickupLine(pickup) }
                    } header: { Text("Pickup line") } footer: {
                        Text("Added to the end of each description when you copy it. Leave empty for none.")
                    }
                }

                Section {
                    LabeledContent("Key") {
                        Text(keySaved ? "Saved on this device" : (KeyStore.built != nil ? "Built into the app" : "Not set"))
                    }
                    SecureField("Paste an Anthropic API key", text: $keyText)
                    if !keyText.isEmpty {
                        Button("Save key") { KeyStore.save(keyText); keyText = ""; keySaved = true }
                    }
                    if keySaved {
                        Button("Remove saved key", role: .destructive) { KeyStore.save(nil); keySaved = false }
                    }
                } header: { Text("Claude (writes listings and looks up prices)") } footer: {
                    Text("Needed on the device that makes listings. Photos go to Anthropic only to write the listing; usage is billed to the key's account.")
                }

                Section {
                    Text("Prices come from similar items found online (eBay, Poshmark, Mercari and others). A price is suggested only when at least 3 were found; it's the middle one, rounded to the dollar. Addy gets 15% of each sale, rounded to the cent (half a cent rounds up).")
                        .font(.footnote)
                } header: { Text("How it works") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.setPickupLine(pickup); dismiss() }
                }
            }
            .onAppear { pickup = model.pickupLine }
            .confirmationDialog("Switch this device to \(model.role == .addy ? "Mom" : "Addy")?", isPresented: $confirmSwitch, titleVisibility: .visible) {
                Button("Switch") {
                    if let code = model.code { model.setUp(role: model.role == .addy ? .mom : .addy, code: code) }
                    dismiss()
                }
            } message: {
                Text("Only for setting up a different device. A family code works with one iPad for Addy and one iPhone for Mom; switching a device that already synced can stop its updates.")
            }
        }
    }
}
