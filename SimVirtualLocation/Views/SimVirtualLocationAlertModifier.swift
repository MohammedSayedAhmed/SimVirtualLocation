import SwiftUI

/// Avoids shadowing `SwiftUI.Alert` and keeps alert presentation in one place.
struct SimVirtualLocationAlertModifier: ViewModifier {
    let isPresented: Binding<Bool>
    let text: String

    func body(content: Content) -> some View {
        content
            .alert(text, isPresented: isPresented) {
                Text("OK")
            }
    }
}
