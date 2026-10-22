import AppKit

/// "Bitirme projesine yaz …": finds the project in the agent app's own records and opens its
/// newest conversation, or a new one in its folder. Never falls back to whatever is open.
@MainActor
enum AgentProjectNavigator {
    enum Outcome {
        case opened(NSRunningApplication, agent: AgentApp, project: AgentProject, isNew: Bool)
        case failed(status: String, spoken: String)
    }

    static func open(_ spoken: String, target: AgentApp, assumed: Bool, newSession: Bool) async -> Outcome {
        // With no app named, Claude first, then Codex.
        let candidates: [AgentApp] = assumed ? [.claudeCode, .codex] : [target]
        var hit: (AgentApp, AgentProject)?
        var ambiguous: [String]?
        for candidate in candidates {
            let isClaude = candidate == .claudeCode
            let projects = await Task.detached { isClaude ? ClaudeProjectStore.load() : CodexProjectStore.load() }.value
            switch AgentProjectMatcher.match(spoken, in: projects) {
            case .found(let project): hit = (candidate, project)
            case .ambiguous(let names): ambiguous = names
            case .none: continue
            }
            break
        }
        guard let (agent, project) = hit else {
            if let names = ambiguous {
                let list = names.prefix(3).joined(separator: ", ")
                return .failed(status: "Hangi proje: \(list)?", spoken: "hangi projeyi kastettiğinizi anlayamadım: \(names.prefix(3).joined(separator: " mi, ")) mi")
            }
            let place = assumed ? "" : "\(target.displayName)'da "
            return .failed(status: "\(place)\(spoken) projesi bulunamadı", spoken: "\(place)\(spoken) adında bir proje bulamadım")
        }
        owLog("[Agent] Project '\(spoken)' → \(agent.displayName) \(project.folder) (session: \(project.latestSession?.title ?? "-"))")
        guard let app = await AgentAppActivator.activate(agent) else {
            return .failed(status: "\(agent.displayName) açılamadı", spoken: "\(agent.displayName) açılamadı")
        }
        let opened: Bool
        if newSession {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project.folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failed(status: "\(project.name) klasörü bulunamadı", spoken: "\(project.name) projesinin klasörünü bulamadım")
            }
            opened = agent == .claudeCode
                ? await ClaudeSessionNavigator.openNewSession(app, folder: project.folder)
                : await CodexSessionNavigator.openNewThread(app, folder: project.folder)
        } else {
            guard let session = project.latestSession else {
                return .failed(status: "\(project.name) projesinde sohbet yok", spoken: "\(project.name) projesinde bir sohbet bulamadım")
            }
            opened = agent == .claudeCode
                ? await ClaudeSessionNavigator.openSession(app, id: session.id, title: session.title)
                : await CodexSessionNavigator.openThread(app, id: session.id, title: session.title)
        }
        guard opened else {
            let status = newSession ? "\(project.name) projesinde yeni session açılamadı" : "\(project.name) projesinin sohbeti açılamadı"
            return .failed(status: status, spoken: status)
        }
        return .opened(app, agent: agent, project: project, isNew: newSession)
    }
}
