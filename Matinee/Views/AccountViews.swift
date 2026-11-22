import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var showCode = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.09, blue: 0.27), Theme.background],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 10) {
                        Image(systemName: "play.tv.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(Theme.accent)
                        Text("Watcher").font(.system(size: 40, weight: .heavy))
                        Text("Sign in with your Stremio account.\nYour addons, library and progress come with you.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 60)

                    VStack(spacing: 12) {
                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .email)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                            .padding(14)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { Task { await signIn() } }
                            .padding(14)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                        if let error {
                            Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            Task { await signIn() }
                        } label: {
                            Group {
                                if working { ProgressView().tint(Theme.onAccent) } else { Text("Sign In").font(.headline) }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Theme.onAccent)
                        .controlSize(.large)
                        .disabled(working || email.isEmpty || password.isEmpty)
                    }

                    VStack(spacing: 8) {
                        Text("Use Apple or Facebook to sign in to Stremio?").font(.footnote).foregroundStyle(.secondary)
                        Button("Sign in with a code") { showCode = true }
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showCode) {
            LinkCodeView()
                .presentationDetents([.medium])
        }
    }

    private func signIn() async {
        guard !working, !email.isEmpty, !password.isEmpty else { return }
        working = true
        error = nil
        do {
            try await model.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}

/// Stremio's link-code sign-in: show a code, the person approves it on a device where they're signed in.
struct LinkCodeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: StremioAPI.LinkCode?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Sign in with a code").font(.title3.weight(.bold)).padding(.top, 24)
            if let code {
                Text(code.code)
                    .font(.system(size: 44, weight: .heavy, design: .monospaced))
                    .kerning(6)
                    .textSelection(.enabled)
                Text("Open the link below on a device where you're signed in to Stremio and enter this code. This screen continues by itself once you approve it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let link = code.link {
                    Button {
                        openURL(link)
                    } label: {
                        Label(link.host() ?? "Open link", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: link) { Label("Send link to another device", systemImage: "square.and.arrow.up") }
                        .font(.footnote)
                }
                ProgressView().padding(.top, 4)
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .task { await run() }
    }

    private func run() async {
        do {
            let created = try await StremioAPI.createLinkCode()
            code = created
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3))
                if let key = try await StremioAPI.readLinkCode(created.code) {
                    try await model.signIn(linkAuthKey: key)
                    dismiss()
                    return
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.engine) private var engine = PlayerEngine.automatic.rawValue
    @AppStorage(Pref.hardwareDecoding) private var hwdec = true
    @AppStorage(Pref.skipSeconds) private var skip = 10
    @AppStorage(Pref.audioLanguages) private var alang = "en,eng"
    @AppStorage(Pref.subtitleLanguages) private var slang = "en,eng"
    @AppStorage(Pref.autoSubtitles) private var autoSubs = false
    @AppStorage(Pref.syncProgress) private var sync = true
    @AppStorage(Pref.resumeAutomatically) private var resume = true
    @AppStorage(Pref.onlyWorkingStreams) private var onlyWorking = true
    @State private var confirmSignOut = false
    @State private var badCount = BadStreams.count

    var body: some View {
        Form {
            Section("Profile") {
                if let profile = model.activeProfile {
                    HStack(spacing: 12) {
                        ProfileAvatar(avatar: profile.avatar, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.body.weight(.semibold))
                            Text(model.email ?? "Signed in to Stremio").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Switch Profile") { model.choosingProfile = true }
                Button("Sign Out and Remove Profile", role: .destructive) { confirmSignOut = true }
            }

            TMDBKeySection()

            Section {
                Picker("Player", selection: $engine) {
                    ForEach(PlayerEngine.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Resume where I left off", isOn: $resume)
                Picker("Skip buttons", selection: $skip) {
                    Text("10 seconds").tag(10)
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                }
            } header: {
                Text("Playback")
            } footer: {
                Text((PlayerEngine(rawValue: engine) ?? .automatic).detail)
            }

            Section {
                Toggle("Hardware decoding", isOn: $hwdec)
                LabeledContent("Audio languages") {
                    TextField("en,eng", text: $alang).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent("Subtitle languages") {
                    TextField("en,eng", text: $slang).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Toggle("Turn on subtitles automatically", isOn: $autoSubs)
            } header: {
                Text("mpv")
            } footer: {
                Text("Languages are comma-separated codes in order of preference. Leave hardware decoding on unless a video stutters or shows green frames.")
            }

            Section {
                Toggle("Only show working streams", isOn: $onlyWorking)
                if badCount > 0 {
                    Button("Unhide \(badCount) stream\(badCount == 1 ? "" : "s") that failed to play") {
                        BadStreams.clear()
                        badCount = 0
                    }
                }
            } header: {
                Text("Streams")
            } footer: {
                Text("Hides torrent-only results, debrid results that still need downloading, links that open outside the app, and streams that failed to play in the last 7 days. Addons with nothing playable are hidden too.")
            }

            Section {
                Toggle("Save progress to Stremio", isOn: $sync)
            } footer: {
                Text("Keeps Continue Watching in sync with Stremio on your other devices.")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .onAppear { badCount = BadStreams.count }
        .confirmationDialog("Sign out and remove \(model.activeProfile?.name ?? "this profile")?",
                            isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { model.signOut() }
        } message: {
            Text("The profile's Stremio library stays in its account; sign in again any time.")
        }
    }
}

/// Where the TMDB key for recommendations goes.
struct TMDBKeySection: View {
    @State private var key = TMDB.apiKey ?? ""
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        Section {
            SecureField("API key or read access token", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Task { await save() }
            } label: {
                HStack {
                    Text(TMDB.isConfigured ? "Update Key" : "Save Key")
                    if checking { Spacer(); ProgressView() }
                }
            }
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            if TMDB.isConfigured {
                Button("Remove Key", role: .destructive) {
                    TMDB.apiKey = nil
                    key = ""
                    status = "Removed. Recommendations now come from your watch history only."
                }
            }
        } header: {
            Text("TMDB (optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let status { Text(status).foregroundStyle(.primary) }
                Text("Recommendations work without a key: Watcher learns from what you watch, using Stremio's catalogs. Optional: add a free TMDB key (themoviedb.org → Settings → API) to mix TMDB's picks into Recommended for You.")
            }
        }
    }

    private func save() async {
        checking = true
        defer { checking = false }
        if await TMDB.validate(key) {
            status = "Key works. TMDB picks will mix into Recommended for You."
        } else {
            status = "TMDB didn't accept that key. Check it and try again."
        }
    }
}

/// Installed addons, in the order Stremio uses them.
struct AddonsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.addons) { addon in
                    HStack(spacing: 14) {
                        RemoteImage(url: addon.manifest.logo, contentMode: .fit, placeholderText: nil)
                            .frame(width: 44, height: 44)
                            .background(Theme.pill)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(addon.manifest.name).font(.headline)
                                if !addon.manifest.version.isEmpty {
                                    Text("v\(addon.manifest.version)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let d = addon.manifest.description, !d.isEmpty {
                                Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Text(capabilities(addon))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("Install or remove addons in any Stremio app or at web.stremio.com, then pull down here to reload.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Addons")
        .refreshable { await model.refresh() }
        .overlay {
            if model.addons.isEmpty {
                if model.isRefreshing { ProgressView() } else {
                    EmptyStateView(symbol: "puzzlepiece.extension", title: "No addons",
                                   message: "Your Stremio account has no addons yet.")
                }
            }
        }
    }

    private func capabilities(_ addon: AddonDescriptor) -> String {
        let names = addon.manifest.resources.map(\.name)
        var parts: [String] = []
        if !addon.manifest.catalogs.isEmpty { parts.append("Catalogs") }
        if names.contains("meta") { parts.append("Details") }
        if names.contains("stream") { parts.append("Streams") }
        if names.contains("subtitles") { parts.append("Subtitles") }
        return parts.joined(separator: " · ")
    }
}
