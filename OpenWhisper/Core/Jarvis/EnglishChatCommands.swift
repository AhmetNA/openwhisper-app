import Foundation

/// Greetings and questions about Jarvis himself in English, while the dictation language is
/// English (`CommandLanguage`). Like `JarvisReply.greeting` and `JarvisReply.meta`, only the
/// whole utterance counts: "good morning, play some music" is left to the command routes.
enum EnglishChatCommands {
    private static func phrase(_ text: String, dropping fillers: Set<String>) -> String {
        text.lowercased(with: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "what's", with: "what is")
            .replacingOccurrences(of: "how's", with: "how is")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty && !fillers.contains($0) }
            .joined(separator: " ")
    }

    static func greeting(in text: String) -> JarvisReply.Greeting? {
        switch phrase(text, dropping: ["jarvis", "hey", "there", "buddy", "mate", "sir"]) {
        case "good morning", "morning": return .goodMorning
        case "hello", "hi", "yo", "greetings", "howdy": return .hello
        case "good afternoon", "good day": return .goodDay
        case "good evening", "evening": return .goodEvening
        case "good night", "goodnight", "night": return .goodNight
        case "how are you", "how are you doing", "how is it going", "what is up", "sup", "how are things",
             "hello how are you", "hi how are you", "good morning how are you", "how have you been":
            return .howAreYou
        default: return nil
        }
    }

    static func meta(in text: String) -> JarvisReply.Meta? {
        switch phrase(text, dropping: ["jarvis", "hey", "sorry", "please", "sir", "again", "you"]) {
        case "what did say", "what was that", "repeat that", "repeat", "say that", "come again", "pardon",
             "can repeat that", "could repeat that", "can say that", "could say that",
             "i didn't hear", "i didn't catch that", "repeat what said", "repeat the last thing":
            return .repeatLast
        case "what do", "what can do", "what are able to do", "what commands do know", "help", "help me",
             "how do i use", "how do use":
            return .help
        case "what can i say", "what can i say here", "what can i do here", "what can do here", "what should i say",
             "which commands can i use here", "what commands can i use here", "what can i say now":
            return .whatCanISay
        case "what did hear", "what did i say", "what did i just say", "what did understand", "read back what i said",
             "what was my last command":
            return .whatDidYouHear
        case "undo the last command", "undo last command", "undo that command", "undo what did", "cancel the last command",
             "undo what just did":
            return .undoLastCommand
        default: return nil
        }
    }
}
