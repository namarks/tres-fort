import SwiftUI

/// Per-group settings: members list, edit-display-name, generate invite,
/// leave group.
///
/// Invite UX is the v1 "manual code" experience (per M5 Q2 decision) —
/// generate a code, show it big, copy + ShareLink as plain text. No
/// deep-link URLs.
struct GroupSettingsView: View {
    let group: GroupSummary
    @ObservedObject var groupModel: GroupModel
    @ObservedObject var auth: AuthModel
    @Environment(\.dismiss) private var dismiss

    @State private var nickname: String = ""
    @State private var savingName = false
    @State private var nameError: String?

    @State private var invite: GroupInviteCode?
    @State private var generating = false
    @State private var inviteError: String?

    @State private var confirmLeave = false
    @State private var leaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(group.members) { m in
                        HStack {
                            Avatar(
                                initials: avatarInitials(from:
                                    m.effective_display_name ?? "Member"),
                                color: .stableAvatarColor(forUserID: m.user_id))
                                .frame(width: 32, height: 32)
                            Text(m.effective_display_name ?? "Member")
                                .font(.body)
                            Spacer()
                            if m.user_id == auth.userID {
                                Text("you").foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("\(group.member_count) member\(group.member_count == 1 ? "" : "s")")
                }

                Section {
                    TextField("Display name", text: $nickname)
                        .textInputAutocapitalization(.words)
                    Button {
                        saveDisplayName()
                    } label: {
                        HStack {
                            Text("Save").bold()
                            Spacer()
                            if savingName { ProgressView() }
                        }
                    }
                    .disabled(savingName)
                    if let nameError {
                        Text(nameError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Your display name")
                } footer: {
                    Text("How you appear in this group. Leave empty to use your default name.")
                }

                Section {
                    if let invite {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(invite.code)
                                .font(.system(.title, design: .monospaced).weight(.bold))
                                .tracking(4)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                            HStack {
                                Button {
                                    UIPasteboard.general.string = invite.code
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                ShareLink(item: shareText(invite.code, groupName: group.name)) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                            }
                            if let exp = invite.expires_at {
                                Text("Expires \(absoluteDate(epochMs: exp))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Never expires")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Generate new code") { generateInvite() }
                                .font(.footnote)
                        }
                    } else {
                        Button {
                            generateInvite()
                        } label: {
                            HStack {
                                Text("Generate invite code").bold()
                                Spacer()
                                if generating { ProgressView() }
                            }
                        }
                        .disabled(generating)
                    }
                    if let inviteError {
                        Text(inviteError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Invite")
                } footer: {
                    Text("Anyone with this 6-character code can join. Codes expire in 30 days.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmLeave = true
                    } label: {
                        HStack {
                            Text("Leave group")
                            Spacer()
                            if leaving { ProgressView() }
                        }
                    }
                    .disabled(leaving)
                }
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Leave \(group.name)?",
                isPresented: $confirmLeave,
                titleVisibility: .visible
            ) {
                Button("Leave", role: .destructive) { leave() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can rejoin later with a fresh invite code.")
            }
            .onAppear {
                // Seed the field with the user's current per-group name.
                nickname = group.myDisplayName(callerUserID: auth.userID) ?? ""
            }
        }
    }

    private func saveDisplayName() {
        savingName = true
        nameError = nil
        let n = nickname.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                _ = try await groupModel.setMyDisplayName(
                    groupID: group.id,
                    name: n.isEmpty ? nil : n)
                savingName = false
            } catch {
                nameError = error.localizedDescription
                savingName = false
            }
        }
    }

    private func generateInvite() {
        generating = true
        inviteError = nil
        Task {
            do {
                let inv = try await groupModel.createInvite(groupID: group.id)
                invite = inv
                generating = false
            } catch {
                inviteError = error.localizedDescription
                generating = false
            }
        }
    }

    private func leave() {
        leaving = true
        Task {
            do {
                try await groupModel.leaveGroup(id: group.id)
                leaving = false
                dismiss()
            } catch {
                leaving = false
            }
        }
    }

    private func shareText(_ code: String, groupName: String) -> String {
        // M5 chose plain text (no URL) per Q2 — Universal Links + deep
        // links are M6. Receivers paste the code into the Join screen.
        "Join \"\(groupName)\" on Très Fort with invite code: \(code)"
    }

    private func absoluteDate(epochMs: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
}
