import AppKit
import SwiftUI

/// The Logs pane at the bottom of the window.
///
/// Observes only `LogStore`, which is the entire point of it being its own view: a log
/// line arrives on almost every code path, and while this lived inside `ContentView`
/// reading the controller, each one invalidated the whole window — map, panel, banner
/// and all — to add a row to a list most of the time nobody was looking at.
struct LogPane: View {

    @ObservedObject var store: LogStore

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))

            if store.isExpanded {
                entries
                    .frame(maxWidth: .infinity, maxHeight: 100)
                    .clipped()
            }
        }
    }

    private var header: some View {
        HStack {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.3)) {
                    store.isExpanded.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: store.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                    Text("Logs")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            if store.isExpanded {
                Button("Copy logs") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.declareTypes([.string], owner: nil)
                    pasteboard.setString(store.exportText, forType: .string)
                }
                .font(.system(size: 11))

                Button("Clear logs") {
                    store.clear()
                }
                .foregroundColor(.red)
                .font(.system(size: 11))
            }
        }
    }

    private var entries: some View {
        ScrollView {
            // Lazy, because a plain VStack in a ScrollView has to build and measure
            // every row to know how tall it is. Four rows are visible and thousands
            // existed, so every redraw laid out the lot.
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(store.entries) { entry in
                    HStack(spacing: 8) {
                        Text(entry.stamp)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                        Text(entry.message)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
