import NookCore
import SwiftUI

/// An invite an assistant prepared. Nothing is on the calendar, and no one is emailed, until Send Invite.
struct EventInviteView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var invite: EventInvite

    init(invite: EventInvite) {
        _invite = State(initialValue: invite)
    }

    private var zone: TimeZone { TimeZone(identifier: invite.timeZone) ?? .current }

    private var canSend: Bool {
        !invite.title.trimmingCharacters(in: .whitespaces).isEmpty && invite.end > invite.start
            && (invite.attendees.trimmingCharacters(in: .whitespaces).isEmpty || !invite.guestEmails.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Calendar invite", systemImage: "calendar.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Text("From").foregroundStyle(.secondary)
                    if let account = store.accounts.first(where: { $0.email == invite.account }) {
                        AccountDot(colorIndex: account.colorIndex)
                    }
                    Text(invite.account)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.primary.opacity(0.05), in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if store.canAddEvents(invite.account) == false {
                permissionNotice
            }

            Form {
                TextField("Title", text: $invite.title)
                DatePicker("Starts", selection: $invite.start)
                DatePicker("Ends", selection: $invite.end)
                LabeledContent("Time zone") {
                    Text(zoneLabel).foregroundStyle(.secondary)
                }
                TextField("Guests", text: $invite.attendees, prompt: Text("name@example.com, …"))
                Toggle("Add a Google Meet link", isOn: $invite.addMeet)
                TextField("Notes", text: $invite.notes, axis: .vertical)
                    .lineLimit(3...6)
            }
            .formStyle(.grouped)
            // The times read and edit in the invite's own zone, which is the zone Google gets.
            .environment(\.timeZone, zone)

            HStack(spacing: 10) {
                Text(invite.guestEmails.isEmpty ? "Adds the event to your calendar" : "Google emails the guests when you send")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { store.eventInvite = nil }
                    .keyboardShortcut(.cancelAction)
                Button {
                    store.sendInvite(invite)
                } label: {
                    HStack(spacing: 6) {
                        Text("Send Invite")
                        Text("⌘↵").font(.system(size: 11)).opacity(0.7)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend || store.canAddEvents(invite.account) == false)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(width: 560)
    }

    /// The account's sign-in predates adding events: say so, and sign in again from here.
    private var permissionNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Calendar access needed").font(.system(size: 12.5, weight: .semibold))
                Text("Nook can't add events to \(invite.account) yet. Sign in again, choose \(invite.account) and tick the Calendar boxes on Google's screen. This invite stays open.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if store.hasGoogleClient {
                Button(store.isSigningIn ? "Waiting for Google…" : "Sign in again") { store.addAccount(hint: invite.account) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSigningIn)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    /// "Asia/Kolkata (GMT+5:30)", and how that compares to this Mac when they differ.
    private var zoneLabel: String {
        let offset = zone.localizedName(for: .shortStandard, locale: .current) ?? ""
        guard zone.identifier != TimeZone.current.identifier else { return "\(zone.identifier) (\(offset))" }
        let local = invite.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(zone.identifier) (\(offset)) · \(local) here"
    }
}
