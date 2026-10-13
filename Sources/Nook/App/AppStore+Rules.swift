import Foundation
import NookCore

extension AppStore {
    /// Saves a rule. With `applyToExisting`, it also files matching mail you already have, in the background.
    func saveRule(_ rule: MailRule, applyToExisting: Bool) {
        do {
            try repo.saveRule(rule)
        } catch {
            showToast(error.localizedDescription, isError: true)
            return
        }
        rules = repo.rules()
        guard applyToExisting else { return }
        let sync = sync
        Task {
            do {
                let changed = try await sync.apply(rule)
                showToast(changed == 0 ? "No emails needed changing" : "Rule applied to \(changed) \(changed == 1 ? "email" : "emails")")
            } catch {
                showToast("Couldn't apply the rule: \(error.localizedDescription)", isError: true)
            }
            reload()
        }
    }

    func deleteRule(_ rule: MailRule) {
        do {
            try repo.deleteRule(id: rule.id)
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
        rules = repo.rules()
    }

    func setRule(_ rule: MailRule, enabled: Bool) {
        var rule = rule
        rule.isEnabled = enabled
        saveRule(rule, applyToExisting: false)
    }

    /// Starts a rule for mail like the open conversation: from its sender, filed out of the inbox.
    func createRuleFromCurrentThread() {
        guard let thread = currentThread else { return }
        let sender = thread.fromEmail.isEmpty ? thread.fromName : thread.fromEmail
        ruleDraft = MailRule(
            name: thread.fromName.isEmpty ? sender : thread.fromName,
            conditions: [RuleCondition(field: .from, value: sender)],
            actions: RuleActions(skipInbox: true)
        )
    }

    /// Recent emails a rule would match, for the editor's preview. Runs off the main thread.
    func previewMatches(for rule: MailRule) async -> RulePreview {
        let repo = repo
        return await Task.detached(priority: .userInitiated) {
            var rule = rule
            rule.isEnabled = true
            guard rule.isValid else { return RulePreview() }
            let matches = repo.recentReceivedMessages(limit: RulePreview.searchLimit).filter(rule.matches)
            return RulePreview(count: matches.count, examples: Array(matches.prefix(3)))
        }.value
    }
}

struct RulePreview: Equatable {
    static let searchLimit = 5000
    var count = 0
    var examples: [MailMessage] = []
}
