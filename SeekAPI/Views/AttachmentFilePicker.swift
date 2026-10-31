import SwiftUI
import UniformTypeIdentifiers

/// Import mode asks the document provider to download/copy its files into the
/// app's sandbox before delivering URLs. No provider URL escapes into a draft.
@MainActor
struct AttachmentFilePicker: UIViewControllerRepresentable {
    let onSelection: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelection: ([URL]) -> Void
        private var delivered = false

        init(onSelection: @escaping ([URL]) -> Void) { self.onSelection = onSelection }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish([]) }

        private func finish(_ urls: [URL]) {
            guard !delivered else { return }
            delivered = true
            onSelection(urls)
        }
    }
}
