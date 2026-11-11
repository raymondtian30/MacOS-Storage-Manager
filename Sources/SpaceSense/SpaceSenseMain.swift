import SwiftUI
import AppKit
import SpaceSenseCore

public final class SpaceSenseAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.applicationIconImage = Self.makeDockIcon()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public static func makeDockIcon(size: CGFloat = 512) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        let rect = NSRect(x: size * 0.08, y: size * 0.08, width: size * 0.84, height: size * 0.84)
        let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.19, yRadius: size * 0.19)

        let bgGradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.28, alpha: 1.0),
            NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.78, alpha: 1.0),
            NSColor(calibratedRed: 0.24, green: 0.72, blue: 0.64, alpha: 1.0)
        ])
        bgGradient?.draw(in: path, angle: -45)

        // Draw stylized storage rings
        let center = NSPoint(x: size * 0.5, y: size * 0.5)
        let outerRing = NSBezierPath()
        outerRing.appendArc(withCenter: center, radius: size * 0.25, startAngle: 0, endAngle: 360)
        NSColor.white.withAlphaComponent(0.22).setStroke()
        outerRing.lineWidth = size * 0.055
        outerRing.stroke()

        let activeArc = NSBezierPath()
        activeArc.appendArc(withCenter: center, radius: size * 0.25, startAngle: 40, endAngle: 310)
        NSColor.white.setStroke()
        activeArc.lineWidth = size * 0.055
        activeArc.lineCapStyle = .round
        activeArc.stroke()

        let innerDot = NSBezierPath(
            ovalIn: NSRect(
                x: center.x - size * 0.07,
                y: center.y - size * 0.07,
                width: size * 0.14,
                height: size * 0.14
            )
        )
        NSColor.white.setFill()
        innerDot.fill()

        img.unlockFocus()
        return img
    }
}

struct SpaceSenseApp: App {
    @NSApplicationDelegateAdaptor(SpaceSenseAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("SpaceSense") {
            MainWindowView(appState: appState)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("Storage") {
                Button("Scan Current Folder") {
                    appState.startScan()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(appState.isScanning)

                Button("Choose Folder to Scan…") {
                    appState.chooseDirectoryAndScan()
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(appState.isScanning)

                if appState.isScanning {
                    Button("Cancel Active Scan") {
                        appState.cancelScan()
                    }
                    .keyboardShortcut(".", modifiers: [.command])
                }

                Divider()

                Button("Refresh System Data") {
                    Task { await appState.refreshSystemData() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(appState.isAnalyzingSystemData)

                Divider()

                Button("Settings…") {
                    appState.selectedSection = .settings
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

@main
enum SpaceSenseLauncher {
    static func main() async {
        if CommandLine.arguments.contains("--self-test") {
            let passed = await SelfTestRunner.runAllTests()
            Foundation.exit(passed ? 0 : 1)
        }
        SpaceSenseApp.main()
    }
}
