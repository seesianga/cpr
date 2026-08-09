import Foundation
import Observation
import OSLog

/// Keeps the measured registration quality for each imported model, before and after
/// alignment.
///
/// This exists to make the overlay's accuracy an observable number rather than a
/// judgement call about whether the body "looks right". The before/after pair is captured
/// on first attach — baseline while the import still sits at its raw export placement,
/// aligned once the solve has been applied — so the improvement is measured rather than
/// asserted.
@MainActor
@Observable
final class PracticeAlignmentReportStore {

    /// Accuracy at the import's own export placement, sampled before any registration.
    private(set) var baseline: [PracticeVisualModel: TorsoAlignmentAccuracy] = [:]
    /// Accuracy of what is on screen right now, re-measured after every change.
    private(set) var alignment: [PracticeVisualModel: TorsoAlignmentAccuracy] = [:]
    private(set) var crop: [PracticeVisualModel: PracticeVisualModelCrop.Outcome] = [:]

    /// Bumped each time a model crosses from misaligned into aligned, so a view can fire
    /// the snap highlight and its cue exactly once instead of on every re-measure.
    private(set) var snapEvent: SnapEvent?

    struct SnapEvent: Equatable, Sendable, Identifiable {
        let id: UUID
        let model: PracticeVisualModel
        let accuracy: TorsoAlignmentAccuracy
    }

    private let logger = Logger(
        subsystem: "com.lifesaver.vision",
        category: "practice-alignment"
    )

    func recordBaseline(_ accuracy: TorsoAlignmentAccuracy?, for model: PracticeVisualModel) {
        guard let accuracy else { return }
        baseline[model] = accuracy
        logger.info(
            "\(model.rawValue, privacy: .public) baseline \(accuracy.summary, privacy: .public)"
        )
    }

    func recordAlignment(_ accuracy: TorsoAlignmentAccuracy?, for model: PracticeVisualModel) {
        guard let accuracy else { return }
        let wasAligned = alignment[model]?.isAligned ?? false
        alignment[model] = accuracy
        if accuracy.isAligned, !wasAligned {
            snapEvent = SnapEvent(id: UUID(), model: model, accuracy: accuracy)
        }
        logger.info(
            "\(model.rawValue, privacy: .public) aligned \(accuracy.summary, privacy: .public)"
        )
    }

    func recordCrop(
        _ outcome: PracticeVisualModelCrop.Outcome?,
        for model: PracticeVisualModel
    ) {
        if let outcome {
            crop[model] = outcome
            logger.info(
                "\(model.rawValue, privacy: .public) crop \(outcome.summary, privacy: .public)"
            )
        } else {
            crop.removeValue(forKey: model)
        }
    }

    func acknowledgeSnap(_ event: SnapEvent) {
        guard snapEvent?.id == event.id else { return }
        snapEvent = nil
    }

    func report(for model: PracticeVisualModel) -> TorsoAlignmentReport? {
        guard let before = baseline[model], let after = alignment[model] else { return nil }
        return TorsoAlignmentReport(before: before, after: after)
    }

    func isAligned(_ model: PracticeVisualModel) -> Bool {
        alignment[model]?.isAligned ?? false
    }

    /// One line per model, for reading out during a demo.
    var demoLines: [String] {
        PracticeVisualModel.allCases.compactMap { model in
            if let report = report(for: model) {
                return "\(model.rawValue): \(report.demoLine)"
            }
            if let accuracy = alignment[model] {
                return "\(model.rawValue): \(accuracy.summary)"
            }
            return nil
        }
    }
}
