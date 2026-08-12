import Foundation

/// Practice target range for VIRTUAL contact travel: the 4–6 cm stroke learners are
/// taught to aim for, applied to the tracked contact node's travel against the virtual
/// chest surface.
///
/// This is a coaching band over interaction geometry. It is NOT a physical
/// compression-depth measurement, it cannot confirm that a real chest was compressed
/// 4–6 cm, and it never contributes to a score. Depth and force remain "not physically
/// assessed" until a `CPRSensorProvider` supplies verified external sensor data.
enum CPRCompressionTravelBand: String, Equatable, Sendable {
    case belowTargetBand
    case withinTargetBand
    case aboveTargetBand

    static let minimumTargetTravelMetres: Float = 0.04
    static let maximumTargetTravelMetres: Float = 0.06

    init(travelMetres: Float) {
        if !travelMetres.isFinite || travelMetres < Self.minimumTargetTravelMetres {
            self = .belowTargetBand
        } else if travelMetres > Self.maximumTargetTravelMetres {
            self = .aboveTargetBand
        } else {
            self = .withinTargetBand
        }
    }

    var isWithinTargetBand: Bool { self == .withinTargetBand }

    var label: String {
        switch self {
        case .belowTargetBand: "Under 40 mm"
        case .withinTargetBand: "40–60 mm"
        case .aboveTargetBand: "Over 60 mm"
        }
    }
}

/// One row of the per-descent contact distance log.
///
/// Every distance here is travel measured against the VIRTUAL torso surface. It is
/// interaction geometry for coaching and detector diagnostics, never a physical
/// compression-depth, force, or recoil measurement.
struct CPRCompressionDistanceLogEntry: Identifiable, Equatable, Sendable {
    /// 1-based chronological position in the retained log.
    let id: Int
    /// Seconds since the oldest retained descent.
    let elapsedSeconds: Double
    /// Distance travelled from the descent's starting height down to its trough.
    let travelMillimetres: Int
    /// How far past the virtual surface the descent bottomed out; 0 when it stayed above.
    let belowSurfaceMillimetres: Int
    let placement: CPRHandPlacementZone
    let isCounted: Bool
    let resolution: CompressionDistanceSample.Resolution
    /// Where this descent's travel sat against the 40–60 mm practice target band.
    let travelBand: CPRCompressionTravelBand

    var elapsedLabel: String {
        String(format: "t+%.1fs", elapsedSeconds)
    }

    var travelLabel: String { "\(travelMillimetres) mm" }

    var belowSurfaceLabel: String { "\(belowSurfaceMillimetres) mm" }

    var placementLabel: String {
        switch placement {
        case .sternumTarget: "Sternum target"
        case .xiphoidAvoidZone: "Xiphoid avoid zone"
        case .outsideTarget: "Outside target"
        case .unavailable: "Placement unavailable"
        }
    }

    /// Why this descent did or did not become a counted compression.
    var statusLabel: String {
        switch (isCounted, resolution) {
        case (true, .releasedNormally): "Counted"
        case (true, .interruptedBeforeRelease): "Counted, tracking lost"
        case (true, .reversedAboveEntryBand): "Counted"
        case (false, .reversedAboveEntryBand): "Near miss, stopped above surface"
        case (false, .releasedNormally): "Not counted, too soon after previous"
        case (false, .interruptedBeforeRelease): "Not counted, tracking lost"
        }
    }

    var accessibilityLabel: String {
        """
        Descent \(id) at \(elapsedLabel): travelled \(travelMillimetres) millimetres, \
        \(travelBand.label) target band, \(belowSurfaceMillimetres) millimetres below \
        the virtual surface, \(placementLabel). \(statusLabel). Interaction distance, \
        not a physical depth measurement.
        """
    }
}

/// Counted-versus-total tally for the log header.
struct CPRCompressionDistanceLogSummary: Equatable, Sendable {
    let countedDescents: Int
    let totalDescents: Int
    /// Counted descents whose virtual travel landed inside the 40–60 mm target band.
    let withinTargetBandDescents: Int

    var label: String {
        "\(countedDescents) counted of \(totalDescents) descents, \(withinTargetBandDescents) in the 40–60 mm band"
    }
}

/// Formats the session's rolling distance log for display. Pure and order-preserving so
/// it can be unit-tested without a view or a live hand-tracking session.
enum CPRCompressionDistanceLogPresenter {
    /// Rows rendered in the immersive panel before older ones are elided.
    static let defaultDisplayLimit = 20

    /// Newest-first rows, capped at `limit`. Numbering and elapsed times stay anchored to
    /// the full retained log, so a row keeps its identity as newer descents push it down.
    static func entries(
        from samples: [CompressionDistanceSample],
        limit: Int = defaultDisplayLimit
    ) -> [CPRCompressionDistanceLogEntry] {
        guard limit > 0, let origin = samples.first?.timestampSeconds else { return [] }

        return samples
            .enumerated()
            .suffix(limit)
            .reversed()
            .map { index, sample in
                CPRCompressionDistanceLogEntry(
                    id: index + 1,
                    elapsedSeconds: max(0, sample.timestampSeconds - origin),
                    travelMillimetres: millimetres(sample.descentDistanceMetres),
                    belowSurfaceMillimetres: millimetres(sample.depthBelowSurfaceMetres),
                    placement: sample.placement,
                    isCounted: sample.countedAsCompression,
                    resolution: sample.resolution,
                    travelBand: CPRCompressionTravelBand(
                        travelMetres: sample.descentDistanceMetres
                    )
                )
            }
    }

    static func summary(
        from samples: [CompressionDistanceSample]
    ) -> CPRCompressionDistanceLogSummary {
        let counted = samples.filter(\.countedAsCompression)
        return CPRCompressionDistanceLogSummary(
            countedDescents: counted.count,
            totalDescents: samples.count,
            withinTargetBandDescents: counted.filter {
                CPRCompressionTravelBand(travelMetres: $0.descentDistanceMetres)
                    .isWithinTargetBand
            }.count
        )
    }

    private static func millimetres(_ metres: Float) -> Int {
        guard metres.isFinite else { return 0 }
        return Int((max(0, metres) * 1000).rounded())
    }
}
