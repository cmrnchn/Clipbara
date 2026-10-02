import SwiftUI
import SwiftData

struct HistoryPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \ClipboardItem.copiedAt, order: .reverse)
    private var items: [ClipboardItem]

    var body: some View {
        ZStack {
            VisualEffectBackground(
                material: colorScheme == .dark ? .hudWindow : .popover
            )
                .ignoresSafeArea()

            VStack(spacing: 0) {
                NavigationBarView()

                ZStack {
                    // Cards layer
                    Group {
                        CardGridView()
                            .opacity(appState.selectedTab == .history ? 1 : 0)
                            .allowsHitTesting(appState.selectedTab == .history)

                        if case .pinboard(let id) = appState.selectedTab {
                            PinboardGridView(pinboardId: id)
                                .id(id)
                        }
                    }
                    .opacity(appState.previewItem == nil ? 1 : 0)

                    // Preview layer (replaces cards)
                    if let previewItem = appState.previewItem {
                        PreviewView(
                            item: previewItem,
                            onClose: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    appState.searchState.selectedIndex = nil
                                    appState.selectForPreview(nil)
                                }
                            },
                            onPaste: {
                                appState.pasteService.paste(item: previewItem)
                                appState.hidePanel()
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)),
                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                        ))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: appState.selectedTab) { _, _ in
                appState.selectForPreview(nil)
            }

            if let toast = appState.panelToast {
                PanelToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.16), value: appState.panelToast)
    }
}

private struct PanelToastView: View {
    let toast: PanelToast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 12, weight: .semibold))

            Text(toast.message)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.primary.opacity(0.86))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, DesignTokens.Nav.height + 8)
        .allowsHitTesting(false)
    }
}
