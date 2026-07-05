import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Przyjmuje upuszczony folder (drag & drop z Findera) i wywoluje akcje.
    func folderDrop(_ action: @escaping (URL) -> Void) -> some View {
        onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }) else {
                return false
            }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                guard let url,
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    return
                }
                DispatchQueue.main.async {
                    action(url)
                }
            }
            return true
        }
    }
}
