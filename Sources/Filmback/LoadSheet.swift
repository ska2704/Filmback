import SwiftUI
import FujiCore

/// What Filmback last knew about one custom bank. The app can't see changes made on the camera itself.
struct CameraBank: Identifiable, Equatable {
    let slot: Int
    let name: String
    let recipe: Recipe
    var id: Int { slot }

    init(slot: Int, name: String, recipe: Recipe) { self.slot = slot; self.name = name; self.recipe = recipe }
    init(_ snapshot: CameraSlotSnapshot) { self.init(slot: snapshot.slot, name: snapshot.name, recipe: snapshot.recipe) }
    init(_ entry: RecipeKitSlot) { self.init(slot: entry.slot, name: PTP.safeName(entry.recipe.name), recipe: entry.recipe) }
}

/// The best evidence of what's on the camera, freshest first, and how it's described on screen.
struct CameraBankSource: Equatable {
    let label: String
    /// Used in sentences such as "Compared with …".
    let description: String
    let banks: [CameraBank]

    static func resolve(lastRead: [CameraSlotSnapshot], loaded: LoadedCatalog?, kits: [RecipeKit],
                        backups: [(title: String, createdAt: Date, banks: [CameraSlotSnapshot])]) -> CameraBankSource? {
        if !lastRead.isEmpty {
            return CameraBankSource(label: "READ THIS SESSION", description: "your last read of the camera", banks: lastRead.map(CameraBank.init))
        }
        let newest = backups.max { $0.createdAt < $1.createdAt }
        // A backup saved before a load shows the old banks, so a later verified load takes priority over it.
        if let loaded, let kit = kits.first(where: { $0.id == loaded.kitID }), kit.updatedAt <= loaded.loadedAt,
           (newest?.createdAt ?? .distantPast) <= loaded.loadedAt {
            let time = loaded.loadedAt.formatted(date: .abbreviated, time: .shortened)
            return CameraBankSource(label: "LOADED: \(kit.name.uppercased()) · \(time.uppercased())", description: "\(kit.name), loaded \(time)", banks: kit.slots.map(CameraBank.init))
        }
        guard let newest else { return nil }
        let time = newest.createdAt.formatted(date: .abbreviated, time: .shortened)
        return CameraBankSource(label: "SAVED READ · \(time.uppercased())", description: "“\(newest.title)”, saved \(time)", banks: newest.banks.map(CameraBank.init))
    }
}

enum EdgeType {
    static func label(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// Fine grain, so flat colour reads as leatherette or paper. Drawn once from a fixed seed.
struct GrainTexture: View {
    let color: Color
    var opacity = 0.05
    var body: some View {
        Canvas { context, size in
            var state: UInt64 = 0x2545F4914F6CDD1D
            func next() -> Double {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return Double(state % 10_000) / 10_000
            }
            let count = min(Int(size.width * size.height / 14), 40_000)
            for _ in 0..<count {
                let rect = CGRect(x: next() * size.width, y: next() * size.height, width: 1, height: 1)
                context.fill(Path(rect), with: .color(color.opacity(next() * opacity)))
            }
        }.drawingGroup().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct BankStatusStamp: View {
    let status: RecipeDiff.BankStatus
    var body: some View {
        switch status {
        case .changed: stamp("CHANGED", marked: true)
        case .noChange: stamp("NO CHANGE", marked: false)
        case .notRead: stamp("NOT READ", marked: false).help("Some settings in this recipe can't be compared with the last read. Back up recipe banks to read them.")
        case .unknown: EmptyView()
        }
    }
    private func stamp(_ text: String, marked: Bool) -> some View {
        HStack(spacing: 4) {
            if marked { Circle().fill(Palette.accent).frame(width: 5, height: 5).accessibilityHidden(true) }
            Text(text).font(EdgeType.label(9, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1).fixedSize()
        }.padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(marked ? Palette.accent : Palette.darkMetal, lineWidth: 1))
    }
}

/// One frame of the sheet: a bank's name, film simulation and dynamic range.
struct FilmCell<Actions: View>: View {
    let slot: Int
    let name: String?
    let recipe: Recipe?
    let status: RecipeDiff.BankStatus
    let emptyText: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("C\(slot)").font(EdgeType.label(20, weight: .semibold))
                BankStatusStamp(status: status)
                Spacer(minLength: 0)
                actions()
            }
            Text(name ?? emptyText).font(.system(size: 13, weight: .semibold)).lineLimit(2, reservesSpace: true)
                .foregroundStyle(name == nil ? Palette.secondary : Palette.ink).help(name ?? "")
            Text(recipe?.settings[.filmSimulation] ?? "—").font(EdgeType.label(11)).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Rectangle().fill(Palette.line).frame(height: 1)
            Text(recipe?.settings[.dynamicRange] ?? "DR not read").font(EdgeType.label(11)).foregroundStyle(Palette.secondary).lineLimit(1)
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.silverHighlight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Bank C\(slot)")
    }
}

/// Four frames on a black strip, with film-edge markings.
struct FilmStrip<Cell: View>: View {
    let edgeLabel: String
    @ViewBuilder let cell: (Int) -> Cell

    var body: some View {
        HStack(spacing: 0) {
            Text(edgeLabel).font(EdgeType.label(8, weight: .medium)).tracking(1.2).foregroundStyle(Palette.sidebarMuted)
                .lineLimit(1).fixedSize().rotationEffect(.degrees(-90)).frame(width: 18).accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 1) {
                    ForEach(1...4, id: \.self) { cell($0).frame(maxWidth: .infinity) }
                }.fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 1) {
                    ForEach(1...4, id: \.self) { number in
                        Text("▶ 0\(number)").font(EdgeType.label(8)).foregroundStyle(Palette.sidebarMuted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                    }
                }.padding(.vertical, 3).accessibilityHidden(true)
            }
        }.padding(.top, 4).padding(.trailing, 4)
            .background(Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct SheetHeading: View {
    let chip: String
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Text(chip).font(EdgeType.label(11, weight: .semibold)).tracking(0.8).foregroundStyle(Palette.sidebarText)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 2))
            Text(text).font(EdgeType.label(10)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}
