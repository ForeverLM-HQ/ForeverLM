// The mirror of a quote selected on a page.
import SwiftUI
import Combine
import AppKit

/// Observes the Page highlight on behalf of the chat panel, so only this
/// empty view re-renders as a highlight is dragged out.
struct PageSelectionQuoteMirror: View {
    @Environment(StudioViewModel.self) private var vm
    let receive: (LivePageSelection?) -> Void

    var body: some View {
        Color.clear
            .onChange(of: vm.livePageSelection, initial: true) { _, selection in
                receive(selection)
            }
    }
}
