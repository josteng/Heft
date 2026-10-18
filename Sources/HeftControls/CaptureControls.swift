import AppIntents
import SwiftUI
import WidgetKit

/// Capture from outside the app: Control Center, the Lock Screen, and the
/// Action button all offer controls, and each of these opens the capture
/// sheet with its destination already chosen.
@main
struct HeftControls: WidgetBundle {
    var body: some Widget {
        CaptureTodayControl()
        CaptureInboxControl()
    }
}

struct CaptureTodayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.stenglein.HeftMobile.captureToday") {
            ControlWidgetButton(action: OpenCaptureIntent(destination: .today)) {
                Label("Add to Today", systemImage: "calendar.badge.plus")
            }
        }
        .displayName("Add to Today's Note")
        .description("Opens Heft to add a line to today's daily note.")
    }
}

struct CaptureInboxControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.stenglein.HeftMobile.captureInbox") {
            ControlWidgetButton(action: OpenCaptureIntent(destination: .inbox)) {
                Label("Capture", systemImage: "tray.and.arrow.down")
            }
        }
        .displayName("Capture to Inbox")
        .description("Opens Heft to add a line to your inbox note.")
    }
}
