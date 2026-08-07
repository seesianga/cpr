import Foundation

struct CohortReportEntry: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let learnerID: String
    let learnerDisplayName: String
    let courseID: String
    let completionFraction: Double?
    let attemptID: String?
    let activityID: String?
    let contentVersion: String
    let score: Double?
    let passed: Bool?
    let criticalErrorCodes: [String]
}

struct CohortReport: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let cohortID: String
    let cohortName: String
    let generatedAt: Date
    let entries: [CohortReportEntry]
}

/// Produces deterministic instructor-authorised CSV and JSON cohort reports.
struct CohortReportExportService: Sendable {
    func jsonData(for report: CohortReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sorted(report))
    }

    func csvData(for report: CohortReport) -> Data {
        var rows = [[
            "Learner ID",
            "Learner name",
            "Course ID",
            "Completion",
            "Attempt ID",
            "Activity ID",
            "Content version",
            "Score",
            "Passed",
            "Critical errors"
        ]]
        rows += sorted(report).entries.map { entry in
            [
                entry.learnerID,
                entry.learnerDisplayName,
                entry.courseID,
                entry.completionFraction.map { String(format: "%.4f", $0) } ?? "",
                entry.attemptID ?? "",
                entry.activityID ?? "",
                entry.contentVersion,
                entry.score.map { String(format: "%.4f", $0) } ?? "",
                entry.passed.map(String.init) ?? "",
                entry.criticalErrorCodes.sorted().joined(separator: "; ")
            ]
        }
        let output = rows
            .map { $0.map(Self.escapeCSV).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
        return Data(output.utf8)
    }

    private func sorted(_ report: CohortReport) -> CohortReport {
        CohortReport(
            schemaVersion: report.schemaVersion,
            cohortID: report.cohortID,
            cohortName: report.cohortName,
            generatedAt: report.generatedAt,
            entries: report.entries.sorted {
                if $0.learnerID != $1.learnerID { return $0.learnerID < $1.learnerID }
                if $0.courseID != $1.courseID { return $0.courseID < $1.courseID }
                return ($0.attemptID ?? "") < ($1.attemptID ?? "")
            }
        )
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") ||
                value.contains("\n") || value.contains("\r")
        else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
