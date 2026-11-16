import SwiftUI

/// "Who's watching?" on Apple TV.
struct TVProfilePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var editor: EditorTarget?

    var body: some View {
        VStack(spacing: 70) {
            Spacer()
            Text(editing ? "Manage Profiles" : "Who's watching?")
                .font(.system(size: 64, weight: .bold))

            HStack(alignment: .top, spacing: 70) {
                ForEach(model.profiles) { profile in
                    TVProfileTile(name: profile.name) {
                        ProfileAvatar(avatar: profile.avatar, size: 220)
                            .overlay {
                                if editing {
                                    RoundedRectangle(cornerRadius: 220 * 0.16, style: .continuous).fill(.black.opacity(0.45))
                                    Image(systemName: "pencil").font(.system(size: 70, weight: .semibold))
                                }
                            }
                    } action: {
                        if editing { editor = .edit(profile) } else { model.select(profile) }
                    }
                }
                if model.profiles.count < 6 {
                    TVProfileTile(name: "Add Profile") {
                        RoundedRectangle(cornerRadius: 220 * 0.16, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .frame(width: 220, height: 220)
                            .overlay { Image(systemName: "plus").font(.system(size: 80, weight: .semibold)).foregroundStyle(.secondary) }
                    } action: {
                        editor = .add
                    }
                }
            }
            .focusSection()

            Button(editing ? "Done" : "Manage Profiles") {
                withAnimation { editing.toggle() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .fullScreenCover(item: $editor) { target in
            TVProfileEditorView(target: target)
        }
    }
}

private struct TVProfileTile<Art: View>: View {
    let name: String
    @ViewBuilder let art: () -> Art
    let action: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Button(action: action) { art() }
                .buttonStyle(.card)
            Text(name).font(.headline).lineLimit(1).frame(width: 240)
        }
    }
}

/// Name and avatar for a new or existing profile, on Apple TV.
struct TVProfileEditorView: View {
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
        HStack(alignment: .top, spacing: 100) {
            VStack(spacing: 30) {
                ProfileAvatar(avatar: avatar, size: 300)
                TextField("Name", text: $name)
                    .frame(width: 420)
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
                if existing != nil {
                    Button("Delete Profile", role: .destructive) { confirmDelete = true }
                } else {
                    Text("Each profile signs in to its own Stremio account so history and recommendations stay separate.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 440)
                }
            }
            .padding(.top, 80)

            VStack(alignment: .leading, spacing: 30) {
                Text("Choose an Avatar").font(.title3.weight(.semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 44), count: 4), spacing: 44) {
                    ForEach(Avatar.all.indices, id: \.self) { i in
                        Button { avatar = i } label: {
                            ProfileAvatar(avatar: i, size: 150)
                                .overlay {
                                    if i == avatar {
                                        RoundedRectangle(cornerRadius: 150 * 0.16, style: .continuous)
                                            .strokeBorder(.white, lineWidth: 6)
                                    }
                                }
                        }
                        .buttonStyle(.card)
                    }
                }
            }
            .padding(.top, 80)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            if let existing {
                name = existing.name
                avatar = existing.avatar
            } else {
                avatar = (model.profiles.map(\.avatar).max() ?? 0) + 1
            }
        }
        .confirmationDialog("Delete \(existing?.name ?? "this profile")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) {
                if let existing { model.deleteProfile(existing.id) }
                dismiss()
            }
        }
    }
}

/// Above Stremio sign-in: whose account this is, with a way back out.
struct TVProfileSignInHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let profile = model.activeProfile {
            HStack(spacing: 24) {
                ProfileAvatar(avatar: profile.avatar, size: 70)
                Text(profile.email == nil ? "New profile: \(profile.name)" : profile.name)
                    .font(.headline)
                if profile.email == nil {
                    Button("Cancel") { model.cancelAddingProfile() }
                } else if model.profiles.count > 1 {
                    Button("Switch Profile") { model.choosingProfile = true }
                }
            }
            .focusSection()
        }
    }
}
