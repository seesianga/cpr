import ARKit
import Foundation

/// The observable lifecycle of hand tracking.
enum HandTrackingState: Equatable, Sendable {
    case idle
    case requestingPermission
    case running
    case permissionDenied
    case unavailable
    case failed(message: String)
}

/// An app-facing boundary around the platform hand-tracking session.
///
/// Implementations report authorization failure as state so callers can provide a
/// graceful non-hand-tracking experience instead of treating denial as a crash.
@MainActor
protocol HandTrackingServicing: AnyObject {
    var state: HandTrackingState { get }

    func start() async
    func stop()
}

/// Owns the ARKit session used for optional hand tracking.
///
/// This phase intentionally exposes no hand-derived clinical measurements. In
/// particular, hand tracking must never be presented as measuring compression
/// depth or force.
@MainActor
final class HandTrackingService: HandTrackingServicing {
    private let session: ARKitSession
    private let provider: HandTrackingProvider

    private(set) var state: HandTrackingState = .idle

    init(
        session: ARKitSession = ARKitSession(),
        provider: HandTrackingProvider = HandTrackingProvider()
    ) {
        self.session = session
        self.provider = provider
    }

    func start() async {
        guard state != .running else {
            return
        }

        guard HandTrackingProvider.isSupported else {
            state = .unavailable
            return
        }

        state = .requestingPermission
        let authorization = await session.requestAuthorization(for: [.handTracking])

        switch authorization[.handTracking] {
        case .allowed:
            do {
                try await session.run([provider])
                state = .running
            } catch {
                state = .failed(message: error.localizedDescription)
            }
        case .denied:
            state = .permissionDenied
        case .notDetermined, .none:
            state = .idle
        @unknown default:
            state = .unavailable
        }
    }

    func stop() {
        session.stop()
        state = .idle
    }
}
