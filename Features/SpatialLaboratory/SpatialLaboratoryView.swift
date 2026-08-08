import Foundation
import RealityKit
import SwiftUI

enum SpatialLaboratoryMode: String, CaseIterable, Identifiable, Sendable {
    case heartAndLungs
    case chainOfSurvival
    case aedExplorer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heartAndLungs: "Heart & Lungs"
        case .chainOfSurvival: "Seven Rings"
        case .aedExplorer: "AED Explorer"
        }
    }
}

struct LaboratoryLessonExcerpt: Sendable, Equatable {
    let blockID: String
    let title: String
    let transcript: String
    let sourceReferences: [SourceReference]
    let reviewStatus: ContentLifecycle

    var narrationCue: AudioCue? {
        guard reviewStatus == .sourceChecked else { return nil }
        return AudioCue(rawValue: "nar.\(blockID)")
    }
}

struct CardiopulmonaryPartDefinition: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let excerpt: LaboratoryLessonExcerpt
}

enum CardiopulmonaryRhythmMode: String, CaseIterable, Identifiable, Sendable {
    case normal
    case simplifiedVF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal-rhythm view"
        case .simplifiedVF: "Simplified VF view"
        }
    }
}

enum CardiopulmonaryMotionStyle: Sendable, Equatable {
    case calmPulse
    case simplifiedVF
    case staticNormal
    case staticVF
}

struct CardiopulmonaryVisualPresentation: Sendable, Equatable {
    let motionStyle: CardiopulmonaryMotionStyle
    let statusText: String

    var isAnimated: Bool {
        motionStyle == .calmPulse || motionStyle == .simplifiedVF
    }

    func heartScale(at tick: Int) -> Float {
        switch motionStyle {
        case .calmPulse:
            [1.0, 1.025, 1.045, 1.02][tick % 4]
        case .simplifiedVF:
            [1.0, 1.035, 1.012, 1.045, 1.018][tick % 5]
        case .staticNormal, .staticVF:
            1.0
        }
    }
}

struct HeartAndLungsLaboratoryModel: Sendable, Equatable {
    let parts: [CardiopulmonaryPartDefinition]
    let normalExcerpt: LaboratoryLessonExcerpt
    let vfExcerpt: LaboratoryLessonExcerpt

    func part(named entityName: String) -> CardiopulmonaryPartDefinition? {
        parts.first { $0.id == entityName }
    }

    func excerpt(for rhythm: CardiopulmonaryRhythmMode) -> LaboratoryLessonExcerpt {
        switch rhythm {
        case .normal: normalExcerpt
        case .simplifiedVF: vfExcerpt
        }
    }

    func visualPresentation(
        for rhythm: CardiopulmonaryRhythmMode,
        reduceMotion: Bool
    ) -> CardiopulmonaryVisualPresentation {
        switch (rhythm, reduceMotion) {
        case (.normal, false):
            CardiopulmonaryVisualPresentation(
                motionStyle: .calmPulse,
                statusText: "Calm abstract pulse and circulation-flow visual"
            )
        case (.simplifiedVF, false):
            CardiopulmonaryVisualPresentation(
                motionStyle: .simplifiedVF,
                statusText: "Abstract simplified-VF visual — not a diagnostic rhythm strip"
            )
        case (.normal, true):
            CardiopulmonaryVisualPresentation(
                motionStyle: .staticNormal,
                statusText: "Static normal-rhythm orientation (Reduce Motion)"
            )
        case (.simplifiedVF, true):
            CardiopulmonaryVisualPresentation(
                motionStyle: .staticVF,
                statusText: "Static simplified-VF orientation (Reduce Motion)"
            )
        }
    }
}

struct ChainRingDefinition: Identifiable, Sendable, Equatable {
    let id: String
    let correctIndex: Int
    let title: String
    let purpose: String
    let orderSources: [SourceReference]
    let purposeSources: [SourceReference]
}

enum ChainActivityCheckResult: Sendable, Equatable {
    case complete
    case orderNeedsReview
    case purposeNeedsReview
    case orderAndPurposeNeedReview

    var message: String {
        switch self {
        case .complete:
            "That matches the provisional seven-ring sequence and each source-backed purpose. This activity remains unscored."
        case .orderNeedsReview:
            "The purposes match. Review the provisional ring order and try again. Nothing is scored."
        case .purposeNeedsReview:
            "The provisional order matches. Review one or more purpose matches and try again. Nothing is scored."
        case .orderAndPurposeNeedReview:
            "Review the ring order and purpose matches, then try again. Nothing is scored."
        }
    }
}

struct ChainOfSurvivalLaboratoryModel: Sendable, Equatable {
    static let isScored = false

    let rings: [ChainRingDefinition]
    let reviewExcerpt: LaboratoryLessonExcerpt
    let purposeExcerpt: LaboratoryLessonExcerpt
    private(set) var orderedRingIDs: [String]
    private(set) var purposeAssignments: [String: String] = [:]
    private(set) var selectedRingID: String?
    private(set) var lastCheck: ChainActivityCheckResult?

    init(
        rings: [ChainRingDefinition],
        reviewExcerpt: LaboratoryLessonExcerpt,
        purposeExcerpt: LaboratoryLessonExcerpt
    ) {
        self.rings = rings
        self.reviewExcerpt = reviewExcerpt
        self.purposeExcerpt = purposeExcerpt
        let learningOrder = [2, 0, 4, 1, 6, 3, 5]
        orderedRingIDs = learningOrder.compactMap { index in
            rings.indices.contains(index) ? rings[index].id : nil
        }
        if orderedRingIDs.count != rings.count {
            orderedRingIDs = rings.map(\.id)
        }
    }

    var correctRingIDs: [String] {
        rings.sorted { $0.correctIndex < $1.correctIndex }.map(\.id)
    }

    var orderedRings: [ChainRingDefinition] {
        orderedRingIDs.compactMap(ring(id:))
    }

    var selectedRing: ChainRingDefinition? {
        selectedRingID.flatMap(ring(id:))
    }

    mutating func select(_ ringID: String) {
        guard ring(id: ringID) != nil else { return }
        selectedRingID = ringID
    }

    @discardableResult
    mutating func move(ringID: String, to destination: Int) -> Bool {
        guard let source = orderedRingIDs.firstIndex(of: ringID),
              !orderedRingIDs.isEmpty
        else { return false }
        let boundedDestination = min(max(0, destination), orderedRingIDs.count - 1)
        guard source != boundedDestination else { return false }
        orderedRingIDs.remove(at: source)
        orderedRingIDs.insert(ringID, at: boundedDestination)
        selectedRingID = ringID
        lastCheck = nil
        return true
    }

    @discardableResult
    mutating func move(ringID: String, by offset: Int) -> Bool {
        guard let source = orderedRingIDs.firstIndex(of: ringID) else { return false }
        return move(ringID: ringID, to: source + offset)
    }

    mutating func assignPurpose(_ purposeRingID: String, to ringID: String) {
        guard ring(id: ringID) != nil, ring(id: purposeRingID) != nil else { return }
        purposeAssignments[ringID] = purposeRingID
        selectedRingID = ringID
        lastCheck = nil
    }

    @discardableResult
    mutating func check() -> ChainActivityCheckResult {
        let orderMatches = orderedRingIDs == correctRingIDs
        let purposesMatch = rings.allSatisfy { purposeAssignments[$0.id] == $0.id }
        let result: ChainActivityCheckResult
        switch (orderMatches, purposesMatch) {
        case (true, true): result = .complete
        case (false, true): result = .orderNeedsReview
        case (true, false): result = .purposeNeedsReview
        case (false, false): result = .orderAndPurposeNeedReview
        }
        lastCheck = result
        return result
    }

    func ring(id: String) -> ChainRingDefinition? {
        rings.first { $0.id == id }
    }
}

struct AEDComponentDefinition: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let excerpt: LaboratoryLessonExcerpt
}

struct AEDLaboratoryModel: Sendable, Equatable {
    let components: [AEDComponentDefinition]
    let preparationCallouts: [LaboratoryLessonExcerpt]

    func component(named entityName: String) -> AEDComponentDefinition? {
        components.first { $0.id == entityName }
    }
}

enum SpatialLaboratoryContentError: Error, LocalizedError, Equatable {
    case missingModule(String)
    case missingBlock(String)
    case invalidReviewStatus(String)
    case missingFact(String)
    case invalidRingOrder
    case invalidRingPurposes

    var errorDescription: String? {
        switch self {
        case let .missingModule(id): "Required course module \(id) is unavailable."
        case let .missingBlock(id): "Required course content \(id) is unavailable."
        case let .invalidReviewStatus(id): "Course content \(id) does not have the required clinical review status."
        case let .missingFact(id): "Required clinical fact \(id) is unavailable."
        case .invalidRingOrder: "The review-gated seven-ring order could not be read safely."
        case .invalidRingPurposes: "The source-backed ring purposes could not be read safely."
        }
    }
}

struct SpatialLaboratoryContent: Sendable, Equatable {
    let heartAndLungs: HeartAndLungsLaboratoryModel
    let chainOfSurvival: ChainOfSurvivalLaboratoryModel
    let aedExplorer: AEDLaboratoryModel

    static func loadBundled(from bundle: Bundle = .main) throws -> Self {
        try make(
            course: CourseContentCodec.loadCourse(named: "course_v1", from: bundle),
            facts: ClinicalFactCatalogue.loadBundled(from: bundle)
        )
    }

    static func make(course: Course, facts: ClinicalFactCatalogue) throws -> Self {
        let m1 = try module("M1", in: course)
        let m2 = try module("M2", in: course)
        let m5 = try module("M5", in: course)

        let anatomy = try sourceCheckedExcerpt("M1-B8", in: m1)
        let vf = try sourceCheckedExcerpt("M1-B4", in: m1)
        let parts = [
            ("heart_ra", "Right atrium"),
            ("heart_rv", "Right ventricle"),
            ("heart_la", "Left atrium"),
            ("heart_lv", "Left ventricle"),
            ("lungs_left", "Left lung"),
            ("lungs_right", "Right lung")
        ].map { id, label in
            CardiopulmonaryPartDefinition(id: id, label: label, excerpt: anatomy)
        }

        let ringOrderExcerpt = try excerpt("M2-B1", in: m2)
        guard ringOrderExcerpt.reviewStatus == .clinicalReviewRequired else {
            throw SpatialLaboratoryContentError.invalidReviewStatus("M2-B1")
        }
        let ringPurposeExcerpt = try sourceCheckedExcerpt("M2-B2", in: m2)
        guard let orderFact = facts["fact.chain.sevenRings"] else {
            throw SpatialLaboratoryContentError.missingFact("fact.chain.sevenRings")
        }
        guard orderFact.reviewStatus == .requiresSMEReview else {
            throw SpatialLaboratoryContentError.invalidReviewStatus(orderFact.id)
        }
        guard case let .array(orderValues)? = orderFact.values["order"] else {
            throw SpatialLaboratoryContentError.invalidRingOrder
        }
        let titles = orderValues.compactMap { value -> String? in
            guard case let .string(title) = value else { return nil }
            return title
        }
        guard titles.count == 7 else {
            throw SpatialLaboratoryContentError.invalidRingOrder
        }
        guard let purposesFact = facts["fact.chain.ringDefinitions"] else {
            throw SpatialLaboratoryContentError.missingFact("fact.chain.ringDefinitions")
        }
        guard purposesFact.reviewStatus == .sourceChecked else {
            throw SpatialLaboratoryContentError.invalidReviewStatus(purposesFact.id)
        }
        let purposes = try ringPurposes(from: purposesFact.statement)
        guard purposes.count == titles.count else {
            throw SpatialLaboratoryContentError.invalidRingPurposes
        }
        let rings = zip(titles.indices, zip(titles, purposes)).map { index, pair in
            ChainRingDefinition(
                id: "chain_ring_\(index + 1)",
                correctIndex: index,
                title: pair.0,
                purpose: pair.1,
                orderSources: ringOrderExcerpt.sourceReferences,
                purposeSources: ringPurposeExcerpt.sourceReferences
            )
        }

        let aedBlockIDs = ["M5-B1", "M5-B3", "M5-B5", "M5-B6", "M5-B7", "M5-B8", "M5-B9", "M5-B10"]
        let aedExcerpts = try Dictionary(uniqueKeysWithValues: aedBlockIDs.map { id in
            (id, try sourceCheckedExcerpt(id, in: m5))
        })
        func aedExcerpt(_ id: String) throws -> LaboratoryLessonExcerpt {
            guard let value = aedExcerpts[id] else {
                throw SpatialLaboratoryContentError.missingBlock(id)
            }
            return value
        }
        let componentMappings: [(String, String, String)] = [
            ("aed_case", "AED trainer case", "M5-B1"),
            ("aed_unit", "AED trainer unit", "M5-B1"),
            ("aed_power_button", "Power button", "M5-B3"),
            ("aed_shock_button", "Simulated shock control", "M5-B1"),
            ("aed_status_light", "Status light", "M5-B3"),
            ("aed_connector", "Pad connector", "M5-B3"),
            ("aed_left_pad", "Left training pad", "M5-B3"),
            ("aed_right_pad", "Right training pad", "M5-B3"),
            ("electrode_packet", "Electrode packet", "M5-B3"),
            ("prep_cloth", "Preparation cloth", "M5-B10"),
            ("training_scissors", "Training scissors", "M5-B5"),
            ("training_razor", "Training razor", "M5-B6"),
            ("glove_box", "Glove box", "M5-B5")
        ]
        let components = try componentMappings.map { id, label, blockID in
            AEDComponentDefinition(id: id, label: label, excerpt: try aedExcerpt(blockID))
        }
        let prepCallouts = try ["M5-B5", "M5-B6", "M5-B7", "M5-B8", "M5-B9", "M5-B10"]
            .map(aedExcerpt)

        return SpatialLaboratoryContent(
            heartAndLungs: HeartAndLungsLaboratoryModel(
                parts: parts,
                normalExcerpt: anatomy,
                vfExcerpt: vf
            ),
            chainOfSurvival: ChainOfSurvivalLaboratoryModel(
                rings: rings,
                reviewExcerpt: ringOrderExcerpt,
                purposeExcerpt: ringPurposeExcerpt
            ),
            aedExplorer: AEDLaboratoryModel(
                components: components,
                preparationCallouts: prepCallouts
            )
        )
    }

    private static func module(_ id: String, in course: Course) throws -> Module {
        guard let module = course.modules.first(where: { $0.id == id }) else {
            throw SpatialLaboratoryContentError.missingModule(id)
        }
        return module
    }

    private static func excerpt(_ id: String, in module: Module) throws -> LaboratoryLessonExcerpt {
        guard let block = module.lessons.lazy.flatMap(\.contentBlocks).first(where: { $0.id == id }) else {
            throw SpatialLaboratoryContentError.missingBlock(id)
        }
        return LaboratoryLessonExcerpt(
            blockID: block.id,
            title: block.title,
            transcript: block.body,
            sourceReferences: block.sourceReferences,
            reviewStatus: block.reviewStatus
        )
    }

    private static func sourceCheckedExcerpt(
        _ id: String,
        in module: Module
    ) throws -> LaboratoryLessonExcerpt {
        let value = try excerpt(id, in: module)
        guard value.reviewStatus == .sourceChecked else {
            throw SpatialLaboratoryContentError.invalidReviewStatus(id)
        }
        return value
    }

    private static func ringPurposes(from statement: String) throws -> [String] {
        let aliases = [
            "Prevention",
            "Early Activation and AED Access",
            "Early CPR",
            "Early Defibrillation",
            "EMS",
            "ACLS",
            "Recovery"
        ]
        var results: [String] = []
        var searchStart = statement.startIndex
        for index in aliases.indices {
            let marker = "\(aliases[index]) = "
            guard let markerRange = statement.range(of: marker, range: searchStart..<statement.endIndex) else {
                throw SpatialLaboratoryContentError.invalidRingPurposes
            }
            let purposeStart = markerRange.upperBound
            let purposeEnd: String.Index
            if aliases.indices.contains(index + 1) {
                let nextMarker = "\(aliases[index + 1]) = "
                guard let nextRange = statement.range(
                    of: nextMarker,
                    range: purposeStart..<statement.endIndex
                ) else {
                    throw SpatialLaboratoryContentError.invalidRingPurposes
                }
                purposeEnd = nextRange.lowerBound
                searchStart = nextRange.lowerBound
            } else {
                purposeEnd = statement.endIndex
                searchStart = statement.endIndex
            }
            let purpose = String(statement[purposeStart..<purposeEnd])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ".")))
            guard !purpose.isEmpty else {
                throw SpatialLaboratoryContentError.invalidRingPurposes
            }
            results.append(purpose)
        }
        return results
    }
}

/// Three-mode volumetric laboratory using only authored semantic models and approved course text.
struct SpatialLaboratoryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(AudioPreferenceKeys.reduceMotion) private var appReduceMotion = false

    @State private var mode = SpatialLaboratoryMode.heartAndLungs
    @State private var laboratoryContent: SpatialLaboratoryContent?
    @State private var chainModel: ChainOfSurvivalLaboratoryModel?
    @State private var contentError: String?
    @State private var sceneError: String?
    @State private var isLoadingScene = true
    @State private var assetRegistry = AssetRegistry()
    @State private var loadedAEDRoot: Entity?
    @State private var chainSlots: [SIMD3<Float>] = []
    @State private var draggedChainRingID: String?
    @State private var selectedHeartPartID: String?
    @State private var rhythm = CardiopulmonaryRhythmMode.normal
    @State private var selectedAEDComponentID: String?
    @State private var selectedAEDCalloutID: String?
    @State private var animationTick = 0
    @State private var narrationNotice: String?

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        ZStack(alignment: .topLeading) {
            laboratoryRealityView

            VStack(alignment: .leading, spacing: 12) {
                Picker("Laboratory", selection: $mode) {
                    ForEach(SpatialLaboratoryMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Selects the volumetric learning model")

                ScrollView {
                    laboratoryPanel
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
            }
            .frame(width: 390, height: 610, alignment: .topLeading)
            .padding(18)
            .glassBackgroundEffect()

            if isLoadingScene {
                ProgressView("Loading \(mode.title)…")
                    .padding(20)
                    .glassBackgroundEffect()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .accessibilityLabel("Loading \(mode.title) laboratory model")
            }
        }
        .overlay(alignment: .bottom) {
            AudioCaptionOverlay(audioDirector: appModel.audioDirector)
                .padding(.bottom, 14)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .task {
            loadApprovedContent()
        }
        .task(id: "\(mode.rawValue)-\(reduceMotion)") {
            await runVisualAnimation()
        }
        .onChange(of: mode) { oldMode, _ in
            release(mode: oldMode)
            sceneError = nil
            narrationNotice = nil
            isLoadingScene = true
            chainSlots = []
        }
        .onDisappear {
            assetRegistry.releaseScene(.heartAndLungsVolume)
            assetRegistry.releaseScene(.chainOfSurvivalVolume)
            loadedAEDRoot?.removeFromParent()
            loadedAEDRoot = nil
            Task { await appModel.audioDirector.stop(.narration) }
        }
    }

    private var laboratoryRealityView: some View {
        RealityView { content in
            do {
                let root = try await loadRoot(for: mode)
                content.add(root)
                isLoadingScene = false
                sceneError = nil
            } catch is CancellationError {
                // Switching laboratory modes cancels the old load without showing an error.
            } catch {
                isLoadingScene = false
                sceneError = error.localizedDescription
            }
        } update: { realityContent in
            updateRealityContent(realityContent)
        }
        .id(mode)
        .gesture(spatialTapGesture)
        .simultaneousGesture(chainDragGesture)
    }

    @ViewBuilder
    private var laboratoryPanel: some View {
        if let contentError {
            unavailablePanel(title: "Learning content unavailable", message: contentError)
        } else if let sceneError {
            unavailablePanel(title: "Spatial model unavailable", message: sceneError)
        } else if let laboratoryContent {
            switch mode {
            case .heartAndLungs:
                heartAndLungsPanel(laboratoryContent.heartAndLungs)
            case .chainOfSurvival:
                if let chainModel {
                    chainPanel(chainModel)
                } else {
                    ProgressView("Preparing unscored activity…")
                }
            case .aedExplorer:
                aedPanel(laboratoryContent.aedExplorer)
            }
        } else {
            ProgressView("Loading approved lesson content…")
        }
    }

    private func heartAndLungsPanel(_ model: HeartAndLungsLaboratoryModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Heart & Lungs Orientation")
                .font(.title2.bold())
            Label(
                "Stylised, non-graphic orientation aid — not a diagnostic or anatomical reference",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Picker("Rhythm visual", selection: $rhythm) {
                ForEach(CardiopulmonaryRhythmMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            let presentation = model.visualPresentation(for: rhythm, reduceMotion: reduceMotion)
            circulationVisual(presentation)

            Text("Select a chamber or lobe")
                .font(.headline)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                ForEach(model.parts) { part in
                    Button {
                        selectedHeartPartID = part.id
                    } label: {
                        HStack {
                            Text(part.label)
                            if selectedHeartPartID == part.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .accessibilityLabel("Selected")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .background(
                        selectedHeartPartID == part.id ? Color.blue.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .accessibilityHint("Shows the approved orientation text for \(part.label)")
                }
            }

            let excerpt = selectedHeartPartID.flatMap(model.part(named:))?.excerpt
                ?? model.excerpt(for: rhythm)
            excerptPanel(excerpt)
        }
    }

    private func circulationVisual(_ presentation: CardiopulmonaryVisualPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ForEach(0..<6, id: \.self) { index in
                    Image(systemName: index <= animationTick % 6 ? "circle.fill" : "circle")
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: animationTick)
            Text(presentation.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.statusText)
    }

    private func chainPanel(_ model: ChainOfSurvivalLaboratoryModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chain of Survival")
                    .font(.title2.bold())
                Spacer()
                Text("UNSCORED")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.18), in: Capsule())
            }
            Label("Awaiting clinical approval", systemImage: "clock.badge.exclamationmark")
                .font(.footnote.bold())
                .foregroundStyle(.orange)
            Text("Drag a ring with gaze and pinch, or use Move Earlier and Move Later. Then match each ring to its source-backed purpose.")
                .font(.footnote)
            Text("The provisional order has no narration and does not affect mastery or scores.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(Array(model.orderedRings.enumerated()), id: \.element.id) { index, ring in
                VStack(alignment: .leading, spacing: 7) {
                    Button {
                        updateChain { $0.select(ring.id) }
                    } label: {
                        HStack {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit().bold())
                                .frame(width: 26, height: 26)
                                .background(.blue.opacity(0.16), in: Circle())
                            Text(ring.title)
                                .font(.subheadline.bold())
                            Spacer()
                            if model.selectedRingID == ring.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .accessibilityLabel("Selected")
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if model.selectedRingID == ring.id {
                        HStack {
                            Button("Earlier", systemImage: "arrow.up") {
                                updateChain { _ = $0.move(ringID: ring.id, by: -1) }
                            }
                            .disabled(index == 0)
                            Button("Later", systemImage: "arrow.down") {
                                updateChain { _ = $0.move(ringID: ring.id, by: 1) }
                            }
                            .disabled(index == model.orderedRings.count - 1)
                        }
                        .buttonStyle(.bordered)

                        Picker(
                            "Purpose for \(ring.title)",
                            selection: purposeBinding(for: ring.id)
                        ) {
                            Text("Choose a purpose").tag("")
                            ForEach(model.rings) { purposeRing in
                                Text(purposeRing.purpose).tag(purposeRing.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .padding(9)
                .background(
                    model.selectedRingID == ring.id ? .blue.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }

            Button("Check order and purposes", systemImage: "checkmark.circle") {
                updateChain { _ = $0.check() }
            }
            .buttonStyle(.borderedProminent)

            if let result = model.lastCheck {
                Label(
                    result.message,
                    systemImage: result == .complete ? "checkmark.circle.fill" : "arrow.counterclockwise.circle"
                )
                .font(.footnote)
                .foregroundStyle(result == .complete ? .primary : .secondary)
                .accessibilityElement(children: .combine)
            }

            excerptPanel(model.reviewExcerpt)
            excerptPanel(model.purposeExcerpt)
        }
    }

    private func aedPanel(_ model: AEDLaboratoryModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AED Component Explorer")
                .font(.title2.bold())
            Label("Brand-neutral, non-functional training model", systemImage: "bolt.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Select a component")
                .font(.headline)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                ForEach(model.components) { component in
                    Button {
                        selectedAEDComponentID = component.id
                        selectedAEDCalloutID = nil
                    } label: {
                        HStack {
                            Text(component.label)
                            if selectedAEDComponentID == component.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .accessibilityLabel("Selected")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .background(
                        selectedAEDComponentID == component.id ? Color.blue.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .accessibilityHint("Shows the approved lesson callout for \(component.label)")
                }
            }

            if let component = selectedAEDComponentID.flatMap(model.component(named:)) {
                excerptPanel(component.excerpt)
            }

            Divider()
            Text("Preparation callouts")
                .font(.headline)
            ForEach(model.preparationCallouts, id: \.blockID) { callout in
                Button {
                    selectedAEDCalloutID = callout.blockID
                    selectedAEDComponentID = nil
                } label: {
                    HStack {
                        Text(callout.title)
                        Spacer()
                        Image(systemName: selectedAEDCalloutID == callout.blockID ? "chevron.down" : "chevron.right")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the source-backed preparation callout")

                if selectedAEDCalloutID == callout.blockID {
                    excerptPanel(callout)
                }
            }
        }
    }

    private func excerptPanel(_ excerpt: LaboratoryLessonExcerpt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(excerpt.title)
                    .font(.headline)
                Spacer()
                if excerpt.reviewStatus == .clinicalReviewRequired {
                    Text("AWAITING APPROVAL")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
            }
            Text(excerpt.transcript)
                .font(.body)

            if let cue = excerpt.narrationCue {
                Button("Play narration", systemImage: "speaker.wave.2.fill") {
                    playNarration(cue)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Plays \(cue.rawValue); the complete transcript remains visible")
            } else {
                Label("Text only by design", systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let narrationNotice {
                Text(narrationNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sourceDisclosure(excerpt.sourceReferences)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func sourceDisclosure(_ references: [SourceReference]) -> some View {
        DisclosureGroup("Sources") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(references) { reference in
                    Text("\(reference.document), \(reference.edition), \(reference.section), p. \(reference.page)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote)
    }

    private func unavailablePanel(title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }

    private var spatialTapGesture: some Gesture {
        TapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                let name = semanticName(startingAt: value.entity)
                switch mode {
                case .heartAndLungs:
                    guard laboratoryContent?.heartAndLungs.part(named: name) != nil else { return }
                    selectedHeartPartID = name
                    playInterfaceSFX("sfx.focus_confirm")
                case .chainOfSurvival:
                    guard chainModel?.ring(id: name) != nil else { return }
                    updateChain { $0.select(name) }
                    playInterfaceSFX("sfx.focus_confirm")
                case .aedExplorer:
                    guard laboratoryContent?.aedExplorer.component(named: name) != nil else { return }
                    selectedAEDComponentID = name
                    selectedAEDCalloutID = nil
                    playInterfaceSFX("sfx.focus_confirm")
                }
            }
    }

    private var chainDragGesture: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard mode == .chainOfSurvival,
                      let ring = semanticEntity(startingAt: value.entity),
                      chainModel?.ring(id: ring.name) != nil,
                      let parent = ring.parent
                else { return }
                if draggedChainRingID != ring.name {
                    draggedChainRingID = ring.name
                    updateChain { $0.select(ring.name) }
                }
                ring.position = value.convert(value.location3D, from: .local, to: parent)
            }
            .onEnded { value in
                defer { draggedChainRingID = nil }
                guard mode == .chainOfSurvival,
                      let ring = semanticEntity(startingAt: value.entity),
                      chainModel?.ring(id: ring.name) != nil,
                      let parent = ring.parent,
                      !chainSlots.isEmpty
                else { return }
                let location = value.convert(value.location3D, from: .local, to: parent)
                let destination = chainSlots.indices.min { left, right in
                    squaredDistance(location, chainSlots[left]) < squaredDistance(location, chainSlots[right])
                } ?? 0
                updateChain { _ = $0.move(ringID: ring.name, to: destination) }
                playInterfaceSFX("sfx.pinch_confirm")
            }
    }

    @MainActor
    private func loadRoot(for mode: SpatialLaboratoryMode) async throws -> Entity {
        switch mode {
        case .heartAndLungs:
            let root = try await assetRegistry.loadScene(.heartAndLungsVolume)
            try assetRegistry.decorateSemanticEntities(in: root, for: .heartAndLungsVolume)
            return root
        case .chainOfSurvival:
            let root = try await assetRegistry.loadScene(.chainOfSurvivalVolume)
            try assetRegistry.decorateSemanticEntities(in: root, for: .chainOfSurvivalVolume)
            chainSlots = (1...7).compactMap { index in
                assetRegistry.firstEntity(named: "chain_ring_\(index)", in: root)?.position
            }
            guard chainSlots.count == 7 else {
                throw AssetRegistryError.semanticEntityMissing(
                    scene: SpatialSceneName.chainOfSurvivalVolume.rawValue,
                    name: "seven authored ring positions"
                )
            }
            return root
        case .aedExplorer:
            let root = try await assetRegistry.loadEntity(named: "AEDTrainer")
            root.name = "AEDTrainer"
            try assetRegistry.decorateAEDTrainerEntities(in: root)
            loadedAEDRoot = root
            return root
        }
    }

    @MainActor
    private func updateRealityContent(_ realityContent: RealityViewContent) {
        switch mode {
        case .heartAndLungs:
            guard let root = realityContent.entities.first(where: {
                $0.name == SpatialSceneName.heartAndLungsVolume.rawValue
            }), let model = laboratoryContent?.heartAndLungs else { return }
            let presentation = model.visualPresentation(for: rhythm, reduceMotion: reduceMotion)
            assetRegistry.firstEntity(named: "heart_model", in: root)?.scale = SIMD3<Float>(
                repeating: presentation.heartScale(at: animationTick)
            )
            for part in model.parts {
                assetRegistry.firstEntity(named: part.id, in: root)?.scale = SIMD3<Float>(
                    repeating: selectedHeartPartID == part.id ? 1.08 : 1.0
                )
            }
        case .chainOfSurvival:
            guard let root = realityContent.entities.first(where: {
                $0.name == SpatialSceneName.chainOfSurvivalVolume.rawValue
            }), let chainModel, chainSlots.count == chainModel.orderedRingIDs.count else { return }
            for (index, ringID) in chainModel.orderedRingIDs.enumerated() {
                guard let ring = assetRegistry.firstEntity(named: ringID, in: root) else { continue }
                if draggedChainRingID != ringID {
                    ring.position = chainSlots[index]
                }
                ring.scale = SIMD3<Float>(repeating: chainModel.selectedRingID == ringID ? 1.08 : 1.0)
            }
        case .aedExplorer:
            break
        }
    }

    private func loadApprovedContent() {
        do {
            let loaded = try SpatialLaboratoryContent.loadBundled()
            laboratoryContent = loaded
            chainModel = loaded.chainOfSurvival
            contentError = nil
        } catch {
            contentError = error.localizedDescription
        }
    }

    private func release(mode: SpatialLaboratoryMode) {
        switch mode {
        case .heartAndLungs:
            assetRegistry.releaseScene(.heartAndLungsVolume)
        case .chainOfSurvival:
            assetRegistry.releaseScene(.chainOfSurvivalVolume)
        case .aedExplorer:
            loadedAEDRoot?.removeFromParent()
            loadedAEDRoot = nil
        }
    }

    private func updateChain(_ update: (inout ChainOfSurvivalLaboratoryModel) -> Void) {
        guard var model = chainModel else { return }
        update(&model)
        chainModel = model
    }

    private func purposeBinding(for ringID: String) -> Binding<String> {
        Binding(
            get: { chainModel?.purposeAssignments[ringID] ?? "" },
            set: { purposeID in
                guard !purposeID.isEmpty else { return }
                updateChain { $0.assignPurpose(purposeID, to: ringID) }
            }
        )
    }

    private func playNarration(_ cue: AudioCue) {
        Task { @MainActor in
            let result = await appModel.audioDirector.play(
                AudioPlaybackRequest(cue: cue, context: .sharedSpace)
            )
            switch result {
            case .started:
                narrationNotice = "Playing \(cue.rawValue). The complete transcript remains visible."
            case .blocked(.missingAsset):
                narrationNotice = "Narration is unavailable; use the complete text shown above."
            case .blocked:
                narrationNotice = "Narration could not start; use the complete text shown above."
            }
        }
    }

    private func playInterfaceSFX(_ id: String) {
        Task {
            _ = await appModel.audioDirector.play(
                AudioPlaybackRequest(
                    cue: AudioCue(rawValue: id),
                    channel: .soundEffects,
                    context: .sharedSpace
                )
            )
        }
    }

    private func runVisualAnimation() async {
        animationTick = 0
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            animationTick = (animationTick + 1) % 60
        }
    }

    private func semanticName(startingAt entity: Entity) -> String {
        semanticEntity(startingAt: entity)?.name ?? entity.name
    }

    private func semanticEntity(startingAt entity: Entity) -> Entity? {
        let semanticNames: Set<String> = Set(
            (laboratoryContent?.heartAndLungs.parts.map(\.id) ?? [])
                + (chainModel?.rings.map(\.id) ?? [])
                + (laboratoryContent?.aedExplorer.components.map(\.id) ?? [])
        )
        var candidate: Entity? = entity
        while let current = candidate {
            if semanticNames.contains(current.name) { return current }
            candidate = current.parent
        }
        return nil
    }

    private func squaredDistance(_ left: SIMD3<Float>, _ right: SIMD3<Float>) -> Float {
        let delta = left - right
        return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
    }
}
