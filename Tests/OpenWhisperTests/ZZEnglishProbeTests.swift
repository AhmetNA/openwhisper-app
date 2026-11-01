import XCTest
@testable import OpenWhisper

@MainActor
final class ZZEnglishProbeTests: XCTestCase {
    func testProbe() async {
        UserDefaults.standard.set("en", forKey: "language")
        defer { UserDefaults.standard.removeObject(forKey: "language") }
        let sentences = [
            "Undo", "Scratch that", "Delete the last word", "Delete the last sentence", "Delete everything", "Clear the field",
            "Press enter", "Replace hello with hi", "Change Monday to Tuesday",
            "Type here: see you tomorrow", "Write this down see you tomorrow",
            "Write to Claude Code fix the login bug", "Send this to Codex add tests for the parser", "Fix the login bug and send it",
            "Switch to Claude Code", "Summarize the last session in Claude",
            "Message Ali: I'll be late", "Send a WhatsApp message to Dilay saying I'm on my way", "Text mom I'm home",
            "Press the Send button", "Click Submit", "Yes", "No", "Yes, send it", "Cancel",
            "Answer me", "Jarvis, what is the capital of France", "Hello", "How are you?", "Remember that my sister's name is Dilay",
            "What did we talk about yesterday?", "Read this article", "Open the last PDF in Downloads", "Move Safari to the left",
            "Open the last link I copied", "How many unread emails do I have?", "Read my latest email", "What's on my schedule today?"
        ]
        for focus in [TextFocusStatus.editable, .notEditable] {
            let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true, focus: focus, hasTargetApp: true,
                                          targetBundleID: "com.anthropic.claudefordesktop", pendingWhatsAppSend: false, lastDictation: "hello world. see you")
            for s in sentences {
                print("PROBE|\(focus)| \(s) | \(VoiceRouter.route(s, facts: facts))")
            }
        }
    }
}
