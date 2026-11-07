import Photos
import SwiftUI
import UIKit

struct MomHome: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Stage = .ready
    @State private var path: [String] = []
    @State private var selling: Item?
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    Text(title).font(.kid(30, .semibold)).foregroundStyle(Theme.ink)
                    tabs
                    let list = model.items(in: tab)
                    if list.isEmpty {
                        empty
                    } else {
                        VStack(spacing: 12) { ForEach(list) { row($0) } }
                    }
                    syncNote
                    if tab == .ready && list.count > 1 {
                        Button("Post all \(list.count), one after another") { path = [list[0].id] }
                            .buttonStyle(ChunkyButtonStyle(fill: Theme.yellow, shadow: Theme.yellowDark, text: Theme.ink, height: 56))
                    }
                }
                .padding(16)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.cream.ignoresSafeArea())
            .refreshable { await model.refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                PostView(id: id) { next in
                    if let next { path = [next] } else { path = [] }
                }
            }
            .sheet(item: $selling) { item in SoldSheet(item: item) }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .tint(Theme.purple)
    }

    private var title: String {
        switch tab {
        case .ready: return "Ready to post"
        case .listed: return "On Marketplace"
        case .sold, .removed: return "Sold"
        }
    }

    private var header: some View {
        HStack {
            Text("Addy's 15%").font(.kid(22, .heavy)).foregroundStyle(Theme.purple)
            Spacer()
            Text("Addy: \(Money.full(model.earnedCents))").font(.kid(15, .heavy)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.white)).overlay(Capsule().strokeBorder(Theme.yellow, lineWidth: 2))
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 18, weight: .bold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Refresh now")
            .disabled(model.syncing)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .foregroundStyle(Theme.purple)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            tabButton(.ready, "Ready")
            tabButton(.listed, "Listed")
            tabButton(.sold, "Sold")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xEFE9DF)))
    }

    private func tabButton(_ s: Stage, _ label: String) -> some View {
        Button { tab = s } label: {
            Text("\(label) · \(model.items(in: s).count)")
                .font(.kid(15, .heavy)).foregroundStyle(tab == s ? Theme.ink : Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 11).fill(tab == s ? Color.white : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == s ? .isSelected : [])
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: tab == .ready ? "tray" : tab == .listed ? "storefront" : "dollarsign.circle")
                .font(.system(size: 44)).foregroundStyle(Theme.purple)
            Text(tab == .ready ? "Nothing waiting. New items from Addy's iPad show up here."
                 : tab == .listed ? "Nothing posted yet." : "No sales yet.")
                .font(.kid(16, .bold)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        let price = model.price(item)
        HStack(spacing: 12) {
            ItemThumb(image: model.image(item.id, 0), side: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.kid(16, .heavy)).foregroundStyle(Theme.ink).lineLimit(2)
                Group {
                    if tab == .sold, let s = model.soldCents(item.id) {
                        Text("Sold \(Money.price(s)) · Addy +\(Money.full(Money.share(s)))")
                    } else {
                        Text("\(price.map(Money.price) ?? "Needs a price") · \(item.condition.label) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.kid(14, .bold)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            switch tab {
            case .ready:
                NavigationLink(value: item.id) { pill("Post", Theme.purple) }
            case .listed:
                Button { selling = item } label: { pill("Sold?", Theme.green) }
            case .sold, .removed:
                EmptyView()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white).shadow(color: Theme.line, radius: 0, y: 2))
        .contentShape(Rectangle())
        .onTapGesture { if tab != .sold { path = [item.id] } }
        .contextMenu {
            if tab == .sold {
                Button("Undo sale") { model.setStage(item.id, .listed) }
            }
            if tab == .listed {
                Button("Move back to Ready") { model.setStage(item.id, .ready) }
            }
            Button("Remove item", role: .destructive) { model.setStage(item.id, .removed) }
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.kid(15, .heavy)).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(color))
    }

    private var syncNote: some View {
        HStack(spacing: 10) {
            Image(systemName: model.syncProblem == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.icloud")
            Group {
                if let p = model.syncProblem { Text(p) }
                else if let d = model.lastSync { Text("Synced with Addy's iPad \(d.formatted(.relative(presentation: .named)))") }
                else { Text("Syncing with Addy's iPad…") }
            }
            .font(.kid(14, .bold))
            Spacer()
        }
        .foregroundStyle(Theme.purpleText)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.lavenderLight))
    }
}

// MARK: - Post one item

struct PostView: View {
    let id: String
    var advance: (String?) -> Void
    @Environment(AppModel.self) private var model
    @State private var toast: String?
    @State private var showComps = false
    @State private var editingPrice = false
    @State private var priceText = ""
    @State private var confirmRemove = false

    var body: some View {
        Group {
            if let item = model.items[id] { content(item) } else { Text("This item isn't here anymore.").font(.kid(18, .bold)) }
        }
        .background(Theme.cream.ignoresSafeArea())
        .navigationTitle(model.stage(id) == .listed ? "On Marketplace" : "Post it")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .overlay(alignment: .top) { if let toast { Toast(text: toast).padding(.top, 8) } }
        .animation(.spring(duration: 0.3), value: toast)
    }

    private func content(_ item: Item) -> some View {
        let price = model.price(item)
        let ready = model.items(in: .ready)
        let position = ready.firstIndex(where: { $0.id == id })
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let position, ready.count > 1 {
                    Text("\(position + 1) of \(ready.count)").font(.kid(14, .bold)).foregroundStyle(Theme.muted)
                }
                TabView {
                    ForEach(0..<max(1, item.photoCount), id: \.self) { n in
                        ZStack {
                            Theme.lavenderLight
                            if let img = model.image(item.id, n) { Image(uiImage: img).resizable().scaledToFit() }
                            else { ProgressView() }
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel("\(item.photoCount) photos")

                Card(padding: 14, radius: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        field("Title") {
                            HStack(alignment: .top) {
                                Text(item.title).font(.kid(17, .heavy)).textSelection(.enabled)
                                Spacer()
                                copyButton("Copy") { copy(item.title, "Title copied") }
                            }
                        }
                        HStack(alignment: .top, spacing: 10) {
                            field("Price") { priceEditor(item, price) }
                            field("Condition") { Text(item.condition.facebook).font(.kid(17, .heavy)) }
                        }
                        if let r = item.compRange {
                            Text("Similar ones online: \(Money.price(r.low)) to \(Money.price(r.high)) (\(item.comps.count) found)")
                                .font(.kid(13, .bold)).foregroundStyle(Theme.muted)
                        }
                        if !item.comps.isEmpty {
                            DisclosureGroup("Where those prices came from", isExpanded: $showComps) {
                                CompList(comps: item.comps, k: 0.8)
                            }
                            .font(.kid(14, .heavy)).tint(Theme.purple)
                        }
                        field("Description") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(fullDescription(item)).font(.kid(15, .semibold)).foregroundStyle(Theme.ink)
                                    .lineSpacing(3).textSelection(.enabled)
                                copyButton("Copy description") { copy(fullDescription(item), "Description copied") }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("In Facebook:").font(.kid(14, .heavy)).foregroundStyle(Theme.muted)
                    step(1, "Add the \(item.photoCount) newest photos")
                    step(2, "Paste the title, then type the price")
                    step(3, "Come back, copy the description, paste it")
                    step(4, "Tap Publish, then \"I posted it\" here")
                }
                .padding(.horizontal, 4)

                Button { Task { await saveAndOpen(item) } } label: {
                    VStack(spacing: 2) {
                        Text("Save photos, copy title, open Facebook")
                        Text("Then come back for the description").font(.kid(13, .bold)).foregroundStyle(Theme.lavenderText)
                    }
                }
                .buttonStyle(ChunkyButtonStyle(fill: Theme.purple, shadow: Theme.purpleDark, height: 66))

                if model.stage(id) == .ready {
                    Button("I posted it") {
                        model.setStage(id, .listed)
                        let next = model.items(in: .ready).first?.id
                        advance(next)
                    }
                    .buttonStyle(ChunkyButtonStyle(fill: Theme.green, shadow: Theme.greenDark, height: 54))
                }

                Button("Remove this item", role: .destructive) { confirmRemove = true }
                    .font(.kid(15, .heavy)).frame(maxWidth: .infinity, minHeight: 44)
                    .confirmationDialog("Remove this item? It won't show on either device.", isPresented: $confirmRemove, titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { model.setStage(id, .removed); advance(nil) }
                    }
            }
            .padding(16)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    private func fullDescription(_ item: Item) -> String {
        let pickup = model.pickupLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return pickup.isEmpty ? item.description : item.description + "\n\n" + pickup
    }

    @ViewBuilder private func priceEditor(_ item: Item, _ price: Int?) -> some View {
        if editingPrice {
            HStack {
                TextField("Price", text: $priceText).keyboardType(.decimalPad).font(.kid(17, .heavy))
                    .frame(minHeight: 44)
                Button("Save") {
                    if let c = Money.parse(priceText) { model.setMomPrice(item.id, c) }
                    editingPrice = false
                }
                .font(.kid(15, .heavy))
            }
        } else {
            Button {
                priceText = price.map { String(format: "%d.%02d", $0 / 100, $0 % 100) } ?? ""
                editingPrice = true
            } label: {
                HStack(spacing: 6) {
                    Text(price.map(Money.price) ?? "Set price").font(.kid(17, .heavy)).foregroundStyle(Theme.ink)
                    Image(systemName: "pencil").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.purple)
                }
                .frame(minHeight: 32)
            }
            .accessibilityLabel("Price \(price.map(Money.price) ?? "not set"). Tap to change.")
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.kid(12, .heavy)).tracking(0.6).foregroundStyle(Theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: "doc.on.doc").font(.kid(14, .heavy)).foregroundStyle(Theme.purple)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(Capsule().fill(Theme.lavenderLight))
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(.kid(13, .heavy)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Theme.purple))
            Text(text).font(.kid(15, .bold)).foregroundStyle(Theme.ink)
        }
    }

    private func copy(_ text: String, _ message: String) {
        UIPasteboard.general.string = text
        show(message)
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == message { toast = nil }
        }
    }

    private func saveAndOpen(_ item: Item) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            show("Allow photo saving in Settings first")
            return
        }
        let urls = model.photoURLs(item)
        do {
            // One at a time, so they land in order in the camera roll.
            for url in urls {
                try await PHPhotoLibrary.shared().performChanges {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
        } catch {
            show("Couldn't save the photos")
            return
        }
        UIPasteboard.general.string = item.title
        if let url = URL(string: "https://www.facebook.com/marketplace/create/item") {
            _ = await UIApplication.shared.open(url)
        }
    }
}

// MARK: - Mark sold

struct SoldSheet: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Int?
    @State private var other = ""
    @FocusState private var otherFocused: Bool

    private var amount: Int? { other.isEmpty ? picked : Money.parse(other) }

    var body: some View {
        let listed = model.price(item)
        let choices: [Int] = {
            guard let p = listed else { return [500, 1000, 1500, 2000] }
            var out: [Int] = []
            for c in [p, p - 100, p - 200, p - 300] where c > 0 && !out.contains(c) { out.append(c) }
            return out
        }()
        VStack(alignment: .leading, spacing: 16) {
            Text("It sold?").font(.kid(30, .semibold)).foregroundStyle(Theme.ink)
            HStack(spacing: 12) {
                ItemThumb(image: model.image(item.id, 0), side: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.kid(16, .heavy)).lineLimit(2)
                    Text(listed.map { "Listed at \(Money.price($0))" } ?? "No price set").font(.kid(14, .bold)).foregroundStyle(Theme.muted)
                }
            }
            Text("What did it sell for?").font(.kid(15, .heavy)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { c in
                    ChoiceChip(selected: other.isEmpty && picked == c, height: 52, action: { picked = c; other = ""; otherFocused = false }) {
                        Text(Money.price(c)).font(.kid(17, .heavy))
                    }
                }
            }
            TextField("Other amount", text: $other)
                .keyboardType(.decimalPad).focused($otherFocused)
                .font(.kid(17, .bold)).padding(.horizontal, 14).frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.lavender, lineWidth: 2))
            HStack {
                Text("Addy's 15%").font(.kid(16, .heavy)).foregroundStyle(Theme.goldText)
                Spacer()
                Text(amount.map { Money.full(Money.share($0)) } ?? "–").font(.kid(32, .heavy)).foregroundStyle(Theme.ink)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.yellowLight))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.yellow, lineWidth: 2))
            Text("Her piggy bank updates on her iPad right away, with a little celebration.")
                .font(.kid(14, .bold)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Button("Mark sold") {
                guard let a = amount else { return }
                model.setStage(item.id, .sold, soldCents: a)
                dismiss()
            }
            .buttonStyle(ChunkyButtonStyle(fill: Theme.green, shadow: Theme.greenDark, height: 58))
            .disabled(amount == nil)
        }
        .padding(20)
        .background(Theme.cream.ignoresSafeArea())
        .presentationDetents([.large])
        .onAppear { picked = choices.first }
    }
}
