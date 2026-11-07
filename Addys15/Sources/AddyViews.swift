import PhotosUI
import SwiftUI

/// Everything about the item Addy is working on, before it becomes a listing.
struct Draft {
    var id = "item-" + UUID().uuidString.lowercased()
    var createdAt = Date()
    var photos: [UIImage] = []          // front, back, tag
    var tagSkipped = false
    var flawPhoto: UIImage?
    var identified: Identified?
    var identifying = false
    var identifyFailed = false
    var sizeFromTag = false
    var kind: Kind?
    var brand = ""
    var size: String?
    var color = ""
    var itemName = ""
    var gender: String?
    var details: [String] = []
    var pieces = 2
    var condition: Condition?
    var hasFlaws: Bool?

    var allPhotos: [UIImage] { photos + (hasFlaws == true ? [flawPhoto].compactMap { $0 } : []) }
    var photosDone: Bool { photos.count >= 3 || (photos.count == 2 && tagSkipped) }
    var canMake: Bool {
        kind != nil && size != nil && condition != nil && hasFlaws != nil && (hasFlaws == false || flawPhoto != nil)
    }
    var guessName: String {
        [brand, itemName.isEmpty ? (kind?.label.lowercased() ?? "") : itemName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The facts handed to Claude for writing the listing.
    var facts: String {
        var lines: [String] = []
        if kind == .bundle { lines.append("Type: a bundle of \(pieces) pieces") } else { lines.append("Type: \(kind?.label ?? "clothing")") }
        lines.append("Brand: \(brand.isEmpty ? "unknown (don't name one)" : brand)")
        lines.append("Size: \(size == nil || size == Sizes.unknown ? "unknown (don't state one)" : size!)")
        if !color.isEmpty { lines.append("Color: \(color)") }
        if let gender { lines.append("For: \(gender)") }
        lines.append("Condition: \(condition?.label ?? "Gently used")")
        lines.append(hasFlaws == true
                     ? "Flaw: yes, shown close up in the last photo. Describe it plainly."
                     : "Flaws: none; the family checked for spots, stains and holes.")
        var p = ["front", "back"]
        if photos.count >= 3 { p.append("tag") }
        if hasFlaws == true, flawPhoto != nil { p.append("close-up of the flaw") }
        lines.append("Photos in order: " + p.joined(separator: ", "))
        if !details.isEmpty { lines.append("Seen in the photos: " + details.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    mutating func apply(_ r: Identified) {
        identified = r
        if kind == nil, let k = r.kind.flatMap(Kind.init(rawValue:)) { kind = k }
        if brand.isEmpty, let b = r.brand?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty, b.lowercased() != "null" { brand = b }
        if size == nil, let s = r.size, !s.trimmingCharacters(in: .whitespaces).isEmpty, s.lowercased() != "null" {
            size = Sizes.normalize(s); sizeFromTag = true
        }
        if color.isEmpty { color = r.color ?? "" }
        if itemName.isEmpty { itemName = r.itemName ?? "" }
        if gender == nil { gender = r.gender }
        details = r.details ?? details
        if let n = r.pieces, n > 1 { pieces = n }
    }
}

enum AddyStep { case snap, tap, making, done, piggy }

struct AddyHome: View {
    @Environment(AppModel.self) private var model
    @State private var step: AddyStep = .snap
    @State private var stepBeforePiggy: AddyStep = .snap
    @State private var draft = Draft()
    @State private var finishedID: String?
    @State private var makeError: String?
    @State private var showSettings = false
    @State private var confirmStartOver = false

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()
            switch step {
            case .snap:
                SnapView(draft: $draft, onDone: { step = .tap; identify() }, onPiggy: openPiggy, onSettings: { showSettings = true },
                         onStartOver: startOver)
            case .tap:
                TapView(draft: $draft, onBack: { step = .snap }, onMake: make, onSettings: { showSettings = true },
                        onStartOver: startOver, onPiggy: openPiggy)
            case .making:
                MakingView(error: makeError, retry: make, back: { step = .tap })
            case .done:
                if let id = finishedID, let item = model.items[id] {
                    DoneView(item: item, onNext: next, onFix: { step = .tap }, onPiggy: openPiggy)
                } else {
                    SnapView(draft: $draft, onDone: { step = .tap; identify() }, onPiggy: openPiggy, onSettings: { showSettings = true },
                             onStartOver: startOver)
                }
            case .piggy:
                PiggyView(onBack: { step = stepBeforePiggy })
            }
        }
        .modifier(ScaledForDevice())
        .sheet(isPresented: $showSettings) { GrownUpGate() }
        .confirmationDialog("Start over with a new item?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Start over", role: .destructive) { next() }
        } message: {
            Text("The pictures and answers for this item will be cleared.")
        }
    }

    private func openPiggy() { stepBeforePiggy = step; step = .piggy }

    private func startOver() {
        if draft.photos.isEmpty && draft.kind == nil { next() } else { confirmStartOver = true }
    }

    private func next() {
        draft = Draft()
        finishedID = nil
        step = .snap
    }

    private func identify() {
        guard draft.identified == nil, !draft.identifying else { return }
        guard let claude = try? Claude() else { draft.identifyFailed = true; return }
        let id = draft.id
        let photos = draft.photos
        draft.identifying = true
        draft.identifyFailed = false
        Task {
            do {
                let r = try await claude.identify(images: photos)
                if draft.id == id { draft.apply(r) }
            } catch {
                if draft.id == id { draft.identifyFailed = true }
            }
            if draft.id == id { draft.identifying = false }
        }
    }

    private func make() {
        makeError = nil
        step = .making
        let d = draft
        Task {
            do {
                let claude = try Claude()
                let r = try await claude.listing(images: d.allPhotos, facts: d.facts)
                guard step == .making, draft.id == d.id else { return }
                let item = model.buildItem(from: d, result: r)
                model.saveItem(item, photos: d.allPhotos)
                finishedID = item.id
                step = .done
            } catch {
                makeError = (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Try again."
            }
        }
    }
}

// MARK: - Header

struct AddyHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.k) private var k
    var onBack: (() -> Void)?
    var onPiggy: (() -> Void)?
    var onSettings: (() -> Void)?
    var onStartOver: (() -> Void)?
    var body: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left").font(.kid(22 * k, .heavy)).foregroundStyle(Theme.purple)
                        .frame(minHeight: 44)
                }
                .frame(width: 110 * k, alignment: .leading)
            }
            Text("Addy's 15%")
                .font(.kid((onBack == nil ? 40 : 32) * k, .heavy))
                .foregroundStyle(Theme.purple)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
            if let onPiggy {
                Button(action: onPiggy) {
                    HStack(spacing: 8 * k) {
                        Image(systemName: "dollarsign.circle.fill").foregroundStyle(Theme.yellowDark)
                        Text(Money.full(model.earnedCents)).foregroundStyle(Theme.ink)
                    }
                    .font(.kid(24 * k, .heavy))
                    .padding(.horizontal, 18 * k).frame(minHeight: max(44, 56 * k))
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().strokeBorder(Theme.yellow, lineWidth: 3))
                }
                .accessibilityLabel("My piggy bank, \(Money.full(model.earnedCents))")
            } else if onBack != nil && onSettings == nil && onStartOver == nil {
                Spacer().frame(width: 110 * k)
            }
            if onSettings != nil || onStartOver != nil {
                Menu {
                    if let onStartOver {
                        Button { onStartOver() } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
                    }
                    if let onPiggy {
                        Button { onPiggy() } label: { Label("My piggy bank", systemImage: "dollarsign.circle") }
                    }
                    if let onSettings {
                        Button { onSettings() } label: { Label("Settings (grown-ups)", systemImage: "gearshape") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 44 * k, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                        .frame(minWidth: 56, minHeight: 56)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Menu")
            }
        }
    }
}

/// Settings sit behind a 2-second press so Addy doesn't change them by accident.
struct GrownUpGate: View {
    @Environment(\.dismiss) private var dismiss
    @State private var unlocked = false
    @State private var holding = false

    var body: some View {
        if unlocked {
            SettingsView()
        } else {
            VStack(spacing: 24) {
                Image(systemName: "lock.fill").font(.system(size: 56)).foregroundStyle(Theme.purple)
                Text("Settings are for grown-ups").font(.kid(30, .semibold)).foregroundStyle(Theme.ink)
                Text("Press and hold the button for 2 seconds.").font(.kid(18, .bold)).foregroundStyle(Theme.muted)
                Text(holding ? "Keep holding…" : "Hold to open")
                    .font(.kid(22, .heavy)).foregroundStyle(.white)
                    .frame(width: 260, height: 80)
                    .background(Capsule().fill(holding ? Theme.purpleDark : Theme.purple))
                    .onLongPressGesture(minimumDuration: 2, pressing: { holding = $0 }) { unlocked = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { unlocked = true }
                Button("Cancel") { dismiss() }.font(.kid(18, .heavy)).foregroundStyle(Theme.purple).frame(minHeight: 44)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.cream.ignoresSafeArea())
        }
    }
}

// MARK: - 1. Snap

struct SnapView: View {
    @Binding var draft: Draft
    var onDone: () -> Void
    var onPiggy: () -> Void
    var onSettings: () -> Void
    var onStartOver: () -> Void
    @Environment(\.k) private var k
    @StateObject private var camera = CameraModel()
    @State private var retake: Int?
    @State private var busy = false
    @State private var flash = false
    @State private var pickerItem: PhotosPickerItem?

    private let names = ["front", "back", "tag"]
    private var target: Int { retake ?? min(draft.photos.count, 2) }
    private var allTaken: Bool { draft.photosDone && retake == nil }

    var body: some View {
        VStack(spacing: 22 * k) {
            AddyHeader(onPiggy: onPiggy, onSettings: onSettings, onStartOver: onStartOver)
            ProgressDots(step: 1)
            Text(allTaken ? "Looks good!" : "Take 3 pictures")
                .font(.kid(44 * k, .semibold)).foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                RoundedRectangle(cornerRadius: 36 * k).fill(Theme.ink)
                switch camera.state {
                case .running, .starting:
                    CameraPreview(camera: camera).clipShape(RoundedRectangle(cornerRadius: 36 * k))
                case .denied:
                    noCamera("Camera is turned off for this app. A grown-up can turn it on in Settings.")
                case .unavailable:
                    noCamera("No camera found.")
                }
                if flash { Color.white.clipShape(RoundedRectangle(cornerRadius: 36 * k)) }
                VStack {
                    Text(allTaken ? "All set" : "Now: the ").font(.kid(26 * k, .heavy)).foregroundStyle(Theme.ink)
                    + Text(allTaken ? "" : names[target].uppercased()).font(.kid(26 * k, .heavy)).foregroundStyle(Theme.purple)
                }
                .padding(.horizontal, 28 * k).padding(.vertical, 14 * k)
                .background(Capsule().fill(Color.white.opacity(0.94)))
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 28 * k)
                if target == 2 && !allTaken {
                    Text("Put the tag in the box")
                        .font(.kid(22 * k, .bold)).foregroundStyle(Theme.yellowLight)
                        .frame(width: 300 * k, height: 110 * k)
                        .overlay(RoundedRectangle(cornerRadius: 20 * k).strokeBorder(Theme.yellow, style: StrokeStyle(lineWidth: 4, dash: [10, 8])))
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 30 * k)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 20 * k) {
                ForEach(0..<3, id: \.self) { i in slot(i) }
            }

            HStack {
                if allTaken {
                    Button("Next") { onDone() }
                        .buttonStyle(ChunkyButtonStyle(fill: Theme.yellow, shadow: Theme.yellowDark, text: Theme.ink, height: 104 * k))
                } else {
                    Group {
                        if target == 2 && retake == nil {
                            Button("No tag? Skip") { draft.tagSkipped = true; onDone() }
                                .font(.kid(22 * k, .bold)).foregroundStyle(Theme.muted).frame(minHeight: 44)
                        } else { Color.clear }
                    }
                    .frame(width: 160 * k, alignment: .leading)
                    Spacer()
                    shutter
                    Spacer()
                    Group {
                        if camera.state == .running || camera.state == .starting { Color.clear } else { library }
                    }
                    .frame(width: 160 * k, alignment: .trailing)
                }
            }
            .frame(height: 132 * k)
        }
        .padding(.horizontal, 48 * k).padding(.vertical, 24 * k)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { add(img) }
                pickerItem = nil
            }
        }
    }

    private func noCamera(_ text: String) -> some View {
        VStack(spacing: 16 * k) {
            Text(text).font(.kid(24 * k, .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
            library
        }
        .padding(30 * k)
    }

    private var library: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            Label("Pick a photo", systemImage: "photo.on.rectangle").font(.kid(20 * k, .heavy))
                .foregroundStyle(Theme.purple).padding(.horizontal, 16).frame(minHeight: 52)
                .background(Capsule().fill(Color.white))
        }
    }

    private var shutter: some View {
        Button(action: shoot) {
            ZStack {
                Circle().fill(Theme.purple)
                Circle().strokeBorder(Color(hex: 0xD9D0FF), lineWidth: 8 * k)
                Image(systemName: "camera.fill").font(.system(size: 50 * k, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 132 * k, height: 132 * k)
        }
        .disabled(busy || camera.state != .running)
        .accessibilityLabel("Take picture of the \(names[target])")
        .sensoryFeedback(.impact, trigger: draft.photos.count)
    }

    @ViewBuilder private func slot(_ i: Int) -> some View {
        let taken = i < draft.photos.count
        let skipped = i == 2 && draft.tagSkipped && !taken
        Button {
            if taken { retake = (retake == i ? nil : i) }
        } label: {
            ZStack {
                if taken {
                    Image(uiImage: draft.photos[i]).resizable().scaledToFill()
                        .frame(maxWidth: .infinity).frame(height: 120 * k).clipped()
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: retake == i ? "arrow.counterclockwise.circle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 34 * k)).foregroundStyle(.white, retake == i ? Theme.purple : Theme.green)
                                .padding(8 * k)
                        }
                } else {
                    VStack(spacing: 6 * k) {
                        Image(systemName: i == 2 ? "tag" : "camera").font(.system(size: 34 * k, weight: .semibold))
                        Text(skipped ? "Skipped" : names[i].capitalized).font(.kid(22 * k, .heavy))
                    }
                    .foregroundStyle(i == target ? Theme.purple : Theme.muted)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 120 * k)
            .background(i == target && !taken ? Theme.lavenderLight : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 24 * k))
            .overlay(RoundedRectangle(cornerRadius: 24 * k).strokeBorder(
                taken ? (retake == i ? Theme.purple : Theme.green) : (i == target ? Theme.purple : Theme.lavender),
                style: StrokeStyle(lineWidth: 3, dash: taken ? [] : [8, 6])))
        }
        .buttonStyle(.plain)
        .disabled(!taken)
        .accessibilityLabel(taken ? "\(names[i]) photo taken. Tap to take it again." : "\(names[i]) photo")
    }

    private func shoot() {
        guard !busy else { return }
        busy = true
        Task {
            if let img = await camera.capture() {
                withAnimation(.easeOut(duration: 0.08)) { flash = true }
                add(img)
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation { flash = false }
            }
            busy = false
        }
    }

    private func add(_ raw: UIImage) {
        let img = raw.resized(maxSide: 1600)
        withAnimation {
            if let r = retake, r < draft.photos.count {
                draft.photos[r] = img
                retake = nil
            } else if draft.photos.count < 3 {
                draft.photos.append(img)
                if draft.photos.count == 3 { draft.tagSkipped = false }
            }
            draft.identified = nil
        }
        if draft.photos.count == 3 && retake == nil { onDone() }
    }
}

// MARK: - 2. Tap

struct TapView: View {
    @Binding var draft: Draft
    var onBack: () -> Void
    var onMake: () -> Void
    var onSettings: () -> Void
    var onStartOver: () -> Void
    var onPiggy: () -> Void
    @Environment(\.k) private var k
    @State private var editingBrand = false
    @State private var showFlawCamera = false
    @FocusState private var brandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22 * k) {
                AddyHeader(onBack: onBack, onPiggy: onPiggy, onSettings: onSettings, onStartOver: onStartOver)
                ProgressDots(step: 2)
            }
            .padding(.horizontal, 48 * k).padding(.top, 24 * k).padding(.bottom, 18 * k)

            ScrollView {
                VStack(alignment: .leading, spacing: 28 * k) {
                    guessCard
                    section("What is it?") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12 * k), count: 5), spacing: 12 * k) {
                            ForEach(Kind.allCases) { kind in
                                ChoiceChip(selected: draft.kind == kind, height: max(48, 76 * k), action: { draft.kind = kind }) {
                                    Text(kind.label).font(.kid(20 * k, .heavy)).minimumScaleFactor(0.7).lineLimit(1)
                                }
                            }
                        }
                        if draft.kind == .bundle { piecesRow }
                    }
                    section("Size", note: draft.sizeFromTag && draft.size != nil && draft.size != Sizes.unknown ? "Found it on the tag!" : nil) {
                        sizeRow
                    }
                    section("How nice is it?") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14 * k), count: 4), spacing: 14 * k) {
                            ForEach(Condition.allCases) { c in
                                ChoiceChip(selected: draft.condition == c, height: max(88, 132 * k), action: { draft.condition = c }) {
                                    VStack(spacing: 8 * k) {
                                        Image(systemName: c.symbol).font(.system(size: 36 * k, weight: .semibold))
                                        Text(c.label).font(.kid(20 * k, .heavy)).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                                    }
                                    .padding(.horizontal, 4)
                                }
                            }
                        }
                    }
                    section("Any spots, stains or holes?") {
                        HStack(spacing: 14 * k) {
                            ChoiceChip(selected: draft.hasFlaws == false, height: max(56, 84 * k), action: { draft.hasFlaws = false }) {
                                Text("Nope, all good").font(.kid(24 * k, .heavy))
                            }
                            ChoiceChip(selected: draft.hasFlaws == true, height: max(56, 84 * k), action: {
                                draft.hasFlaws = true
                                if draft.flawPhoto == nil { showFlawCamera = true }
                            }) {
                                Text("Yes, I'll show you").font(.kid(24 * k, .heavy))
                            }
                        }
                        if draft.hasFlaws == true { flawRow }
                    }
                }
                .padding(.horizontal, 48 * k).padding(.bottom, 24 * k)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 8 * k) {
                if !draft.canMake {
                    Text("Answer every question to make your listing").font(.kid(18 * k, .bold)).foregroundStyle(Theme.muted)
                }
                Button(action: onMake) {
                    Label("Make my listing", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(ChunkyButtonStyle(fill: Theme.yellow, shadow: Theme.yellowDark, text: Theme.ink, height: max(64, 104 * k)))
                .disabled(!draft.canMake)
            }
            .padding(.horizontal, 48 * k).padding(.vertical, 16 * k)
            .background(Theme.cream)
        }
        .sheet(isPresented: $showFlawCamera) {
            FlawCameraSheet { img in draft.flawPhoto = img }
                .modifier(ScaledForDevice())
        }
    }

    private var guessCard: some View {
        Card(padding: 18 * k, radius: 28 * k) {
            HStack(spacing: 22 * k) {
                ItemThumb(image: draft.photos.first, side: 130 * k)
                VStack(alignment: .leading, spacing: 6 * k) {
                    if draft.identifying {
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.purple)
                            Text("Looking at your pictures…").font(.kid(24 * k, .bold)).foregroundStyle(Theme.muted)
                        }
                    } else if draft.identified != nil {
                        Text("I think this is a…").font(.kid(20 * k, .bold)).foregroundStyle(Theme.muted)
                        Text(draft.guessName.isEmpty ? "piece of clothing" : draft.guessName)
                            .font(.kid(34 * k, .semibold)).foregroundStyle(Theme.ink).lineLimit(2).minimumScaleFactor(0.6)
                        Text("Wrong? Tap anything below to fix it.").font(.kid(18 * k, .bold)).foregroundStyle(Theme.muted)
                    } else {
                        Text(draft.identifyFailed ? "I couldn't tell this time." : "Tell me about it!")
                            .font(.kid(30 * k, .semibold)).foregroundStyle(Theme.ink)
                        Text("Tap the answers below.").font(.kid(18 * k, .bold)).foregroundStyle(Theme.muted)
                    }
                    brandRow
                }
            }
        }
    }

    private var brandRow: some View {
        HStack(spacing: 8) {
            Text("Brand:").font(.kid(20 * k, .bold)).foregroundStyle(Theme.muted)
            if editingBrand {
                TextField("Type the brand", text: $draft.brand)
                    .font(.kid(22 * k, .heavy)).textInputAutocapitalization(.words).autocorrectionDisabled()
                    .focused($brandFocused).submitLabel(.done)
                    .onSubmit { editingBrand = false }
                    .padding(.horizontal, 10).frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.purple, lineWidth: 2))
            } else {
                Button {
                    editingBrand = true
                    brandFocused = true
                } label: {
                    HStack(spacing: 6) {
                        Text(draft.brand.isEmpty ? "Tap to add" : draft.brand).font(.kid(22 * k, .heavy))
                        Image(systemName: "pencil").font(.system(size: 18 * k, weight: .bold))
                    }
                    .foregroundStyle(Theme.purple).frame(minHeight: 44)
                }
                .accessibilityLabel("Brand: \(draft.brand.isEmpty ? "none" : draft.brand). Tap to change.")
            }
        }
    }

    private var piecesRow: some View {
        HStack(spacing: 16 * k) {
            Text("How many pieces?").font(.kid(22 * k, .bold)).foregroundStyle(Theme.ink)
            Spacer()
            Button { draft.pieces = max(2, draft.pieces - 1) } label: { Image(systemName: "minus.circle.fill").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Fewer pieces")
            Text("\(draft.pieces)").font(.kid(34 * k, .heavy)).frame(minWidth: 50 * k)
            Button { draft.pieces = min(30, draft.pieces + 1) } label: { Image(systemName: "plus.circle.fill").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("More pieces")
        }
        .font(.system(size: 44 * k)).foregroundStyle(Theme.purple)
        .padding(.top, 6)
    }

    private var sizeRow: some View {
        let sizes = Sizes.list(for: draft.kind, including: draft.size)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 12 * k) {
                    ForEach(sizes, id: \.self) { s in
                        ChoiceChip(selected: draft.size == s, height: max(52, 76 * k), action: { draft.size = s }) {
                            Text(s).font(.kid(22 * k, .heavy)).lineLimit(1).padding(.horizontal, 14 * k)
                        }
                        .frame(minWidth: 86 * k)
                        .id(s)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.visible)
            .onAppear { if let s = draft.size { proxy.scrollTo(s, anchor: .center) } }
            .onChange(of: draft.size) { _, s in if let s { withAnimation { proxy.scrollTo(s, anchor: .center) } } }
        }
    }

    private var flawRow: some View {
        HStack(spacing: 16 * k) {
            if let img = draft.flawPhoto {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 96 * k, height: 96 * k)
                    .clipShape(RoundedRectangle(cornerRadius: 18 * k)).accessibilityLabel("Photo of the flaw")
                Text("Thanks for being honest!").font(.kid(20 * k, .bold)).foregroundStyle(Theme.green)
            } else {
                Text("Take a close-up of the spot so buyers can see it.").font(.kid(20 * k, .bold)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button(draft.flawPhoto == nil ? "Take it" : "Retake") { showFlawCamera = true }
                .font(.kid(20 * k, .heavy)).foregroundStyle(Theme.purple).frame(minHeight: 44)
        }
        .padding(.top, 6)
    }

    private func section<C: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12 * k) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.kid(28 * k, .semibold)).foregroundStyle(Theme.ink)
                if let note { Text(note).font(.kid(18 * k, .bold)).foregroundStyle(Theme.green) }
            }
            content()
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) { configuration.title; configuration.icon }
    }
}

struct FlawCameraSheet: View {
    var onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.k) private var k
    @StateObject private var camera = CameraModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Show the spot up close").font(.kid(30 * k, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel").font(.kid(20, .heavy)).foregroundStyle(Theme.purple)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(Theme.ink)
                if camera.state == .running || camera.state == .starting {
                    CameraPreview(camera: camera).clipShape(RoundedRectangle(cornerRadius: 28))
                } else {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Text("Pick a photo").font(.kid(22, .heavy)).foregroundStyle(Theme.purple)
                            .padding(.horizontal, 20).frame(minHeight: 52).background(Capsule().fill(Color.white))
                    }
                }
            }
            Button {
                guard !busy else { return }
                busy = true
                Task {
                    if let img = await camera.capture() { onPhoto(img.resized(maxSide: 1600)); dismiss() }
                    busy = false
                }
            } label: {
                Image(systemName: "camera.fill").font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 110, height: 110).background(Circle().fill(Theme.purple))
            }
            .disabled(busy || camera.state != .running)
            .accessibilityLabel("Take picture of the flaw")
        }
        .padding(28)
        .background(Theme.cream)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    onPhoto(img.resized(maxSide: 1600)); dismiss()
                }
            }
        }
    }
}

// MARK: - Making (waiting for Claude)

struct MakingView: View {
    var error: String?
    var retry: () -> Void
    var back: () -> Void
    @Environment(\.k) private var k
    @State private var message = 0
    @State private var bounce = false
    private let messages = ["Writing your listing…", "Checking prices online…", "Finding similar ones…", "Almost done…"]

    var body: some View {
        VStack(spacing: 30 * k) {
            Spacer()
            if let error {
                Image(systemName: "cloud.drizzle.fill").font(.system(size: 90 * k)).foregroundStyle(Theme.purple)
                Text("Oops!").font(.kid(56 * k, .heavy)).foregroundStyle(Theme.ink)
                Text(error).font(.kid(26 * k, .bold)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("Try again", action: retry)
                    .buttonStyle(ChunkyButtonStyle(fill: Theme.purple, shadow: Theme.purpleDark, height: max(64, 100 * k)))
                Button("Go back", action: back).font(.kid(24 * k, .heavy)).foregroundStyle(Theme.purple).frame(minHeight: 44)
            } else {
                Image(systemName: "sparkles").font(.system(size: 110 * k, weight: .semibold)).foregroundStyle(Theme.purple)
                    .scaleEffect(bounce ? 1.12 : 0.92)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: bounce)
                Text(messages[message]).font(.kid(44 * k, .semibold)).foregroundStyle(Theme.ink)
                    .contentTransition(.opacity).animation(.easeInOut, value: message)
                Text("This can take up to a minute.").font(.kid(22 * k, .bold)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(48 * k)
        .frame(maxWidth: .infinity)
        .onAppear { bounce = true }
        .task(id: error == nil) {
            while error == nil && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                message = (message + 1) % messages.count
            }
        }
    }
}

// MARK: - 3. Done

struct DoneView: View {
    let item: Item
    var onNext: () -> Void
    var onFix: () -> Void
    var onPiggy: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.k) private var k
    @State private var showComps = false

    var body: some View {
        let price = model.price(item)
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 26 * k) {
                    ProgressDots(step: 3)
                    VStack(spacing: 8 * k) {
                        Text("Nice job, Addy!").font(.kid(64 * k, .heavy)).foregroundStyle(Theme.purple).minimumScaleFactor(0.6).lineLimit(1)
                        Text("Your listing is ready.").font(.kid(24 * k, .bold)).foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 30 * k)

                    Card(padding: 26 * k, radius: 32 * k) {
                        VStack(alignment: .leading, spacing: 18 * k) {
                            HStack(alignment: .top, spacing: 20 * k) {
                                ItemThumb(image: model.image(item.id, 0), side: 150 * k)
                                VStack(alignment: .leading, spacing: 10 * k) {
                                    Text(item.title).font(.kid(30 * k, .semibold)).foregroundStyle(Theme.ink)
                                    FlowChips(chips: chips, k: k)
                                }
                            }
                            Text(item.description).font(.kid(22 * k, .medium)).foregroundStyle(Theme.ink).lineSpacing(4)
                            Divider()
                            priceRow(price)
                            if !item.comps.isEmpty {
                                DisclosureGroup(isExpanded: $showComps) {
                                    CompList(comps: item.comps, k: k, linksEnabled: false)
                                } label: {
                                    Text("See the \(item.comps.count) similar \(item.comps.count == 1 ? "one" : "ones") I found")
                                        .font(.kid(18 * k, .heavy)).foregroundStyle(Theme.purple)
                                }
                                .tint(Theme.purple)
                            }
                        }
                    }

                    syncBanner

                    VStack(spacing: 14 * k) {
                        Button(action: onNext) { Label("Next item", systemImage: "camera.fill") }
                            .buttonStyle(ChunkyButtonStyle(fill: Theme.purple, shadow: Theme.purpleDark, height: max(64, 104 * k)))
                        HStack(spacing: 14 * k) {
                            Button("Fix something", action: onFix).buttonStyle(SoftButtonStyle(k: k))
                            Button("My piggy bank", action: onPiggy).buttonStyle(SoftButtonStyle(k: k))
                        }
                    }
                }
                .padding(.horizontal, 48 * k).padding(.vertical, 40 * k)
            }
            Confetti()
        }
    }

    private var chips: [(String, Color, Color)] {
        var c: [(String, Color, Color)] = [(item.condition.label, Theme.lavenderLight, Theme.purpleText)]
        c.append(item.hasFlaws ? ("Flaw shown in photos", Theme.yellowLight, Theme.goldText)
                               : ("No stains or holes", Theme.greenLight, Theme.greenDark))
        return c
    }

    @ViewBuilder private func priceRow(_ price: Int?) -> some View {
        if let price {
            HStack(alignment: .center, spacing: 16 * k) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Price").font(.kid(18 * k, .bold)).foregroundStyle(Theme.muted)
                    if model.momSetPrice(item.id) {
                        Text(Money.price(price)).font(.kid(44 * k, .heavy)).foregroundStyle(Theme.ink).monospacedDigit()
                        Text("Mom set the price").font(.kid(16 * k, .bold)).foregroundStyle(Theme.muted)
                    } else {
                        HStack(spacing: 14 * k) {
                            Button { model.setAddyPrice(item.id, max(100, price - 100)) } label: {
                                Image(systemName: "minus.circle.fill").frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Lower the price by a dollar").disabled(price <= 100)
                            Text(Money.price(price)).font(.kid(44 * k, .heavy)).foregroundStyle(Theme.ink).monospacedDigit()
                            Button { model.setAddyPrice(item.id, price + 100) } label: {
                                Image(systemName: "plus.circle.fill").frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Raise the price by a dollar")
                        }
                        .font(.system(size: 36 * k)).foregroundStyle(Theme.purple)
                    }
                    if let r = item.compRange {
                        Text("Similar ones sell for \(Money.price(r.low)) to \(Money.price(r.high))")
                            .font(.kid(16 * k, .bold)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                VStack(spacing: 2) {
                    Text("If it sells, you get").font(.kid(18 * k, .heavy)).foregroundStyle(Theme.goldText)
                    Text(Money.full(Money.share(price))).font(.kid(40 * k, .heavy)).foregroundStyle(Theme.ink)
                }
                .padding(.horizontal, 22 * k).padding(.vertical, 16 * k)
                .background(RoundedRectangle(cornerRadius: 24 * k).fill(Theme.yellowLight))
                .overlay(RoundedRectangle(cornerRadius: 24 * k).strokeBorder(Theme.yellow, lineWidth: 3))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Price: Mom will pick it").font(.kid(28 * k, .heavy)).foregroundStyle(Theme.ink)
                Text(item.comps.isEmpty ? "I couldn't find similar ones online to compare."
                                        : "I only found \(item.comps.count) similar \(item.comps.count == 1 ? "one" : "ones") online, not enough to be sure.")
                    .font(.kid(18 * k, .bold)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var syncBanner: some View {
        let pending = model.pendingUploads.contains(item.id)
        return HStack(spacing: 14 * k) {
            Image(systemName: pending ? "arrow.triangle.2.circlepath" : "iphone").font(.system(size: 30 * k, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(pending ? "Sending to Mom's phone…" : "Sent to Mom's phone to post!").font(.kid(22 * k, .heavy))
                if pending, let p = model.syncProblem { Text(p).font(.kid(16 * k, .bold)) }
            }
            Spacer()
        }
        .foregroundStyle(pending ? Theme.purpleText : Theme.greenDark)
        .padding(.horizontal, 22 * k).padding(.vertical, 18 * k)
        .background(RoundedRectangle(cornerRadius: 24 * k).fill(pending ? Theme.lavenderLight : Theme.greenLight))
    }
}

struct SoftButtonStyle: ButtonStyle {
    var k: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kid(22 * k, .heavy)).foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: max(52, 76 * k))
            .background(RoundedRectangle(cornerRadius: 24 * k).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 24 * k).strokeBorder(Theme.lavender, lineWidth: 3))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct FlowChips: View {
    let chips: [(String, Color, Color)]
    let k: CGFloat
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
    @ViewBuilder private var content: some View {
        ForEach(chips.indices, id: \.self) { i in
            Text(chips[i].0).font(.kid(17 * k, .heavy)).foregroundStyle(chips[i].2)
                .padding(.horizontal, 14 * k).padding(.vertical, 6 * k)
                .background(Capsule().fill(chips[i].1))
        }
    }
}

struct CompList: View {
    let comps: [Comp]
    let k: CGFloat
    /// Off on Addy's screens, so she can't leave the app for other websites.
    var linksEnabled = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(comps.indices, id: \.self) { i in
                let c = comps[i]
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if linksEnabled, let url = URL(string: c.url), url.scheme?.hasPrefix("http") == true {
                            Link(c.title.isEmpty ? c.source : c.title, destination: url)
                                .font(.kid(16 * k, .bold)).foregroundStyle(Theme.purpleText).lineLimit(2)
                        } else {
                            Text(c.title.isEmpty ? c.source : c.title).font(.kid(16 * k, .bold)).lineLimit(2)
                        }
                        Text(c.source).font(.kid(14 * k, .semibold)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(Money.full(c.priceCents)).font(.kid(18 * k, .heavy)).foregroundStyle(Theme.ink).monospacedDigit()
                }
            }
            Text("Prices other sellers asked or got online. Marketplace prices are often a little lower.")
                .font(.kid(14 * k, .semibold)).foregroundStyle(Theme.muted)
        }
        .padding(.top, 8)
    }
}

// MARK: - 4. Piggy bank

struct PiggyView: View {
    var onBack: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.k) private var k
    @State private var celebrate = false

    private let goals = [500, 1000, 2500, 5000, 10000, 25000, 50000, 100000]

    var body: some View {
        let earned = model.earnedCents
        let active = model.activeItems
        let sold = model.items(in: .sold)
        let waiting = model.items(in: .ready).count
        let forSale = model.items(in: .listed).count
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26 * k) {
                    AddyHeader(onBack: onBack)

                    HStack(spacing: 30 * k) {
                        Image(systemName: "dollarsign.circle.fill").font(.system(size: 130 * k)).foregroundStyle(Theme.ink, Theme.yellow)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("You've earned").font(.kid(24 * k, .heavy)).foregroundStyle(Theme.lavenderText)
                            Text(Money.full(earned)).font(.kid(88 * k, .heavy)).foregroundStyle(.white).minimumScaleFactor(0.5).lineLimit(1)
                            Text(sold.isEmpty ? "Your 15% shows up here when something sells."
                                              : "15% of each sale · \(Money.full(model.soldTotalCents)) sold")
                                .font(.kid(20 * k, .bold)).foregroundStyle(Theme.lavenderText)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(36 * k)
                    .background(RoundedRectangle(cornerRadius: 36 * k).fill(Theme.purple))
                    .accessibilityElement(children: .combine)

                    HStack(spacing: 16 * k) {
                        stat("\(waiting)", "Waiting for Mom")
                        stat("\(forSale)", "For sale")
                        stat("\(sold.count)", "Sold")
                    }

                    if let goal = goals.first(where: { $0 > earned }) {
                        VStack(alignment: .leading, spacing: 10 * k) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Next goal: \(Money.price(goal))").font(.kid(26 * k, .semibold))
                                Spacer()
                                Text("\(Money.full(goal - earned)) to go").font(.kid(20 * k, .heavy)).foregroundStyle(Theme.muted)
                            }
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.lavender)
                                    Capsule().fill(Theme.yellow).frame(width: max(28 * k, g.size.width * CGFloat(earned) / CGFloat(goal)))
                                }
                            }
                            .frame(height: 28 * k)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    VStack(alignment: .leading, spacing: 12 * k) {
                        Text("My badges").font(.kid(26 * k, .semibold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12 * k), count: 3), spacing: 12 * k) {
                            badge("First sale", "star.fill", sold.count >= 1)
                            badge("10 made", "tshirt.fill", active.count >= 10)
                            badge("$10 earned", "dollarsign.circle.fill", earned >= 1000)
                            badge("$25 earned", "gift.fill", earned >= 2500)
                            badge("50 made", "trophy.fill", active.count >= 50)
                            badge("$50 earned", "crown.fill", earned >= 5000)
                        }
                    }

                    if !sold.isEmpty {
                        VStack(alignment: .leading, spacing: 12 * k) {
                            Text("Recent sales").font(.kid(26 * k, .semibold))
                            Card(padding: 0, radius: 26 * k) {
                                VStack(spacing: 0) {
                                    ForEach(Array(sold.enumerated()), id: \.element.id) { i, item in
                                        if i > 0 { Divider().padding(.horizontal, 22 * k) }
                                        saleRow(item)
                                    }
                                }
                            }
                        }
                    }

                    if !active.isEmpty {
                        VStack(alignment: .leading, spacing: 12 * k) {
                            Text("My items").font(.kid(26 * k, .semibold))
                            Card(padding: 0, radius: 26 * k) {
                                VStack(spacing: 0) {
                                    ForEach(Array(active.enumerated()), id: \.element.id) { i, item in
                                        if i > 0 { Divider().padding(.horizontal, 22 * k) }
                                        itemRow(item)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 48 * k).padding(.vertical, 24 * k)
            }
            .refreshable { await model.refresh() }
            if celebrate { Confetti() }
        }
        .onAppear {
            if model.earnedCents > model.seenEarnedCents { celebrate = true }
            model.markEarningsSeen()
        }
        .onChange(of: model.earnedCents) { old, new in
            if new > old { celebrate = false; DispatchQueue.main.async { celebrate = true } }
            model.markEarningsSeen()
        }
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(n).font(.kid(44 * k, .heavy)).foregroundStyle(Theme.ink)
            Text(label).font(.kid(19 * k, .heavy)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20 * k)
        .background(RoundedRectangle(cornerRadius: 24 * k).fill(Color.white).shadow(color: Theme.line, radius: 0, y: 2))
        .accessibilityElement(children: .combine)
    }

    private func badge(_ title: String, _ symbol: String, _ won: Bool) -> some View {
        VStack(spacing: 6 * k) {
            Image(systemName: won ? symbol : "lock.fill").font(.system(size: 32 * k, weight: .semibold))
                .foregroundStyle(won ? Theme.goldText : Theme.muted)
            Text(title).font(.kid(16 * k, .heavy)).foregroundStyle(won ? Theme.ink : Theme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 110 * k)
        .background(RoundedRectangle(cornerRadius: 22 * k).fill(won ? Theme.yellowLight : Color.white))
        .overlay(RoundedRectangle(cornerRadius: 22 * k).strokeBorder(won ? Theme.yellow : Theme.lavender,
                                                                      style: StrokeStyle(lineWidth: 3, dash: won ? [] : [8, 6])))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) badge, \(won ? "earned" : "not yet")")
    }

    private func saleRow(_ item: Item) -> some View {
        let s = model.soldCents(item.id) ?? 0
        return HStack(spacing: 16 * k) {
            Text(item.title).font(.kid(21 * k, .heavy)).lineLimit(1)
            Spacer()
            Text("Sold \(Money.price(s))").font(.kid(19 * k, .bold)).foregroundStyle(Theme.muted)
            Text("+\(Money.full(Money.share(s)))").font(.kid(24 * k, .heavy)).foregroundStyle(Theme.green)
                .frame(minWidth: 90 * k, alignment: .trailing)
        }
        .padding(.horizontal, 22 * k).padding(.vertical, 18 * k)
    }

    private func itemRow(_ item: Item) -> some View {
        let st = model.stage(item.id)
        let (label, fg, bg): (String, Color, Color) = {
            switch st {
            case .ready: return ("Waiting for Mom", Theme.purpleText, Theme.lavenderLight)
            case .listed: return ("For sale", Theme.goldText, Theme.yellowLight)
            case .sold: return ("Sold!", Theme.greenDark, Theme.greenLight)
            case .removed: return ("Removed", Theme.muted, Theme.lavenderLight)
            }
        }()
        return HStack(spacing: 14 * k) {
            ItemThumb(image: model.image(item.id, 0), side: 64 * k)
            Text(item.title).font(.kid(19 * k, .bold)).lineLimit(2)
            Spacer()
            Text(label).font(.kid(16 * k, .heavy)).foregroundStyle(fg)
                .padding(.horizontal, 12 * k).padding(.vertical, 6 * k).background(Capsule().fill(bg))
        }
        .padding(.horizontal, 18 * k).padding(.vertical, 12 * k)
    }
}
