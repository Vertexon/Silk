import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `public.python-script` when the system knows it, plain text otherwise.
    static var pythonFile: UTType {
        UTType(filenameExtension: "py") ?? .plainText
    }
}

/// Document wrapper used by the editor's Open/Save commands.
struct PythonDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.pythonFile, .plainText, .sourceCode]
    }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Document wrapper used to export files read out of Pyodide's virtual FS.
struct WorkspaceFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
