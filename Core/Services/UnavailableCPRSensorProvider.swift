import Foundation

/// Safe production default until an explicitly verified external CPR sensor is integrated.
///
/// Vision-derived hand signals never pass through this boundary and can never populate physical
/// compression depth or force. Callers must display both values as "Not physically assessed".
struct UnavailableCPRSensorProvider: CPRSensorProvider {
    var isVerifiedExternalSensorConnected: Bool {
        get async { false }
    }

    func latestMeasurement() async throws -> CPRSensorMeasurement? {
        nil
    }
}
