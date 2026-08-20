//
//  QuickTopmostSurfaces.swift
//  QuickRecorder
//

import SwiftUI

private let quickTopmostLive = Color(red: 0.874, green: 0.180, blue: 0.153)

/// The pill that rides on the window being recorded.
struct QuickTopmostPillView: View {
    @ObservedObject private var state = QuickTopmostRecordingState.shared
    @State private var elapsed = QuickTopmostElapsed.text(0)

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(quickTopmostLive)
                .frame(width: 8, height: 8)
            Text("Recording this window")
                .font(.system(size: 12.5, weight: .semibold))
            Text("\u{00B7}")
                .font(.system(size: 12.5))
                .opacity(0.34)
            Text(elapsed)
                .font(.system(size: 12).monospacedDigit())
                .opacity(0.78)
            Button(action: { state.requestStop() }) {
                Text("Stop")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(quickTopmostLive, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.9), in: Capsule())
        .onReceive(updateTimer) { _ in elapsed = state.snapshot(at: Date()).elapsed }
    }
}

/// The menu-bar surface that stays put for the whole recording.
struct QuickTopmostIndicatorView: View {
    @ObservedObject private var state = QuickTopmostRecordingState.shared
    @State private var elapsed = QuickTopmostElapsed.text(0)

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.white)
                .frame(width: 7, height: 7)
            Text("Quick Topmost")
                .font(.system(size: 12, weight: .semibold))
            Text(elapsed)
                .font(.system(size: 12).monospacedDigit())
            Button(action: { state.requestStop() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(quickTopmostLive, in: RoundedRectangle(cornerRadius: 5))
        .onReceive(updateTimer) { _ in elapsed = state.snapshot(at: Date()).elapsed }
    }
}

/// Owns the on-window pill panel and moves the shared recording state that both Quick
/// Topmost surfaces read.
final class QuickTopmostPresence {
    static let shared = QuickTopmostPresence()

    private var pill: NSPanel?

    func activate(_ target: QuickTopmostPillTarget) {
        QuickTopmostRecordingState.shared.begin(windowTitle: target.windowTitle, at: Date())
        showPill(over: target.windowFrame)
    }

    func dismiss() {
        DispatchQueue.main.async {
            self.pill?.orderOut(nil)
            self.pill = nil
            QuickTopmostRecordingState.shared.end()
        }
    }

    private func showPill(over windowFrame: CGRect) {
        let host = NSHostingView(rootView: QuickTopmostPillView())
        let size = host.fittingSize
        let windowRect = CGRectTransform(cgRect: windowFrame)
        let panel = NSPanel(
            contentRect: NSRect(
                x: windowRect.minX + 12,
                y: windowRect.maxY - 40 - size.height,
                width: size.width,
                height: size.height
            ),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        QuickTopmostPillWindowSettings.excludedFromCapture.apply(to: panel)
        panel.contentView = host
        panel.orderFront(nil)
        pill = panel
    }
}
