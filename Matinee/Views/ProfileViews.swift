import SwiftUI

/// "Who's watching?": pick a profile, add one, or edit them.
struct ProfilePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sizing) private var sizing
    @State private var editing = false
    @State private var editor: EditorTarget?

    static let maxProfiles = 6

    var body: some View {
        let tile: CGFloat = sizing.regular ? 140 : 104
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(editing ? "Done" : "Edit") {
                        withAnimation(.snappy) { editing.toggle() }
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, sizing.hPad)
                    .padding(.top, 8)
                }
                Spacer(minLength: 20)
                Text(editing ? "Manage Profiles" : "Who's watching?")
                    .font(.system(size: sizing.regular ? 40 : 30, weight: .bold))
                    .padding(.bottom, sizing.regular ? 44 : 32)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: sizing.regular ? 36 : 24), count: sizing.regular ? 3 : 2),
                          spacing: sizing.regular ? 36 : 26) {
                    ForEach(model.profiles) { profile in
                        Button {
                            if editing { editor = .edit(profile) } else { model.select(profile) }
                        } label: {
                            VStack(spacing: 10) {
                                ProfileAvatar(avatar: profile.avatar, size: tile)
                                    .overlay {
                                        if editing {
                                            RoundedRectangle(cornerRadius: tile * 0.16, style: .continuous)
                                                .fill(.black.opacity(0.45))
                                            Image(systemName: "pencil")
                                                .font(.system(size: tile * 0.28, weight: .semibold))
                                        }
                                    }
                                Text(profile.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .foregroundStyle(profile.id == model.activeProfileId ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(editing ? "Edit \(profile.name)" : profile.name)
                    }

                    if model.profiles.count < Self.maxProfiles {
                        Button {
                            editor = .add
                        } label: {
                            VStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: tile * 0.16, style: .continuous)
                                    .strokeBorder(.white.opacity(0.25), lineWidth: 2)
                                    .frame(width: tile, height: tile)
                                    .overlay {
                                        Image(systemName: "plus")
                                            .font(.system(size: tile * 0.34, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                Text("Add Profile").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 40)
                Spacer(minLength: 40)
            }
        }
        .sheet(item: $editor) { target in
            ProfileEditorView(target: target)
                .presentationDetents([.large])
        }
    }
}

/// Name and avatar for a new or existing profile.
struct ProfileEditorView: View {
    let target: EditorTarget
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatar = 0
    @State private var confirmDelete = false

    private var existing: Profile? {
        if case .edit(let p) = target { return p }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ProfileAvatar(avatar: avatar, size: 110)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }

                Section("Avatar") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(Avatar.all.indices, id: \.self) { i in
                            Button { avatar = i } label: {
                                ProfileAvatar(avatar: i, size: 62)
                                    .overlay {
                                        if i == avatar {
                                            RoundedRectangle(cornerRadius: 62 * 0.16, style: .continuous)
                                                .strokeBorder(.white, lineWidth: 3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                if existing == nil {
                    Section {
                        Text("Each profile signs in to its own Stremio account, so watch history, Continue Watching and recommendations stay separate. You can make a free account at stremio.com.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }

                if let existing {
                    Section {
                        Button("Delete Profile", role: .destructive) { confirmDelete = true }
                    } footer: {
                        if let mail = existing.email { Text("Signed in to Stremio as \(mail).") }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(existing == nil ? "Add Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Continue" : "Save") {
                        if let existing {
                            model.updateProfile(existing.id, name: name, avatar: avatar)
                            dismiss()
                        } else {
                            dismiss()
                            model.addProfile(name: name, avatar: avatar)
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \(existing?.name ?? "this profile")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Profile", role: .destructive) {
                    if let existing { model.deleteProfile(existing.id) }
                    dismiss()
                }
            } message: {
                Text("This removes the profile from this device and signs it out of Stremio. Its Stremio library isn't deleted.")
            }
        }
        .onAppear {
            if let existing {
                name = existing.name
                avatar = existing.avatar
            } else {
                avatar = (model.profiles.map(\.avatar).max() ?? 0) + 1
            }
        }
    }
}

/// Shown above Stremio sign-in when the profile still needs an account (or a new session).
struct ProfileSignInHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let profile = model.activeProfile {
            HStack(spacing: 10) {
                ProfileAvatar(avatar: profile.avatar, size: 34)
                Text(profile.email == nil ? "New profile: \(profile.name)" : profile.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if profile.email == nil {
                    Button("Cancel") { model.cancelAddingProfile() }
                        .font(.subheadline.weight(.semibold))
                } else if model.profiles.count > 1 {
                    Button("Switch Profile") { model.choosingProfile = true }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }
}

/// The current profile's avatar; tap to switch profiles.
struct ProfileButton: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 40

    var body: some View {
        if let profile = model.activeProfile {
            Button {
                model.choosingProfile = true
            } label: {
                ProfileAvatar(avatar: profile.avatar, size: size)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile: \(profile.name). Switch profile")
        }
    }
}
