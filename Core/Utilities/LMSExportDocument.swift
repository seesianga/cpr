import SwiftUI
import UniformTypeIdentifiers

/// A small, dependency-free document wrapper used by privacy and cohort exports.
struct LMSExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.json, .commaSeparatedText]
    }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
