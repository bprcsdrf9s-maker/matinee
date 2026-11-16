import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

// MARK: - Sign in

/// Sign in by scanning a code with your phone (no typing with the remote), or with email and password.
struct TVSignInView: View {
    @Environment(AppModel.self) private var model
    @State private var code: StremioAPI.LinkCode?
    @State private var codeError: String?
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        HStack(alignment: .center, spacing: 140) {
            VStack(spacing: 28) {
                HStack(spacing: 18) {
                    Image(systemName: "play.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.accent)
                    Text("Watcher").font(.system(size: 72, weight: .heavy))
                }
                Text("Scan with your phone to sign in")
                    .font(.title3.weight(.semibold))

                Group {
                    if let code {
                        let target = code.link?.absoluteString ?? "https://link.stremio.com"
                        if let qr = QRCode.image(for: target) {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 340, height: 340)
                                .padding(22)
                                .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                    } else if let codeError {
                        Text(codeError).foregroundStyle(.red).frame(width: 384, height: 384)
                    } else {
                        ProgressView().frame(width: 384, height: 384)
                    }
                }

                if let code {
                    VStack(spacing: 8) {
                        Text("or go to \(code.link?.host() ?? "link.stremio.com") and enter")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(code.code)
                            .font(.system(size: 56, weight: .heavy, design: .monospaced))
                            .kerning(8)
                    }
                }
            }
            .frame(width: 640)

            VStack(alignment: .leading, spacing: 24) {
                Text("Or sign in with email")
                    .font(.title3.weight(.semibold))
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Button {
                    Task { await signIn() }
                } label: {
                    Group {
                        if working { ProgressView() } else { Text("Sign In") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || email.isEmpty || password.isEmpty)
                Text("Your addons, library and Continue Watching come with you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 620)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [Color(red: 0.13, green: 0.09, blue: 0.27), Theme.background],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .task { await runLinkCode() }
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

    /// Shows a link code and waits for it to be approved on another device. Codes expire, so get a new one every 5 minutes.
    private func runLinkCode() async {
        while !Task.isCancelled && !model.isSignedIn {
            do {
                let created = try await StremioAPI.createLinkCode()
                code = created
                codeError = nil
                let expires = Date().addingTimeInterval(300)
                while !Task.isCancelled && Date() < expires {
                    try await Task.sleep(for: .seconds(3))
                    if let key = try await StremioAPI.readLinkCode(created.code) {
                        try await model.signIn(linkAuthKey: key)
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                codeError = "Couldn't get a sign-in code. Check the Apple TV's internet connection."
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Settings

struct TVSettingsView: View {
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
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(Theme.accent)
                Text("Settings").font(.title.weight(.bold))
                if let profile = model.activeProfile {
                    HStack(spacing: 16) {
                        ProfileAvatar(avatar: profile.avatar, size: 64)
                        Text(profile.name).font(.headline)
                    }
                }
                Text(model.email ?? "Signed in to Stremio")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(width: 520)
            .padding(.top, 60)

            Form {
                Section {
                    Button("Switch Profile") { model.choosingProfile = true }
                } header: {
                    Text("Profile")
                }

                TVTMDBKeySection()

                Section {
                    Picker("Player", selection: $engine) {
                        ForEach(PlayerEngine.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Resume Where I Left Off", isOn: $resume)
                    Picker("Skip Buttons", selection: $skip) {
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
                    Toggle("Hardware Decoding", isOn: $hwdec)
                    Toggle("Turn On Subtitles Automatically", isOn: $autoSubs)
                    LabeledContent("Audio Languages") {
                        TextField("en,eng", text: $alang)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    LabeledContent("Subtitle Languages") {
                        TextField("en,eng", text: $slang)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("mpv")
                } footer: {
                    Text("Languages are comma-separated codes in order of preference.")
                }

                Section {
                    Toggle("Only Show Working Streams", isOn: $onlyWorking)
                    if badCount > 0 {
                        Button("Unhide \(badCount) Stream\(badCount == 1 ? "" : "s") That Failed to Play") {
                            BadStreams.clear()
                            badCount = 0
                        }
                    }
                } header: {
                    Text("Streams")
                }

                Section {
                    Toggle("Save Progress to Stremio", isOn: $sync)
                } footer: {
                    Text("Keeps Continue Watching in sync with Stremio on your other devices.")
                }

                Section {
                    ForEach(model.addons) { addon in
                        LabeledContent(addon.manifest.name, value: addon.manifest.version.isEmpty ? "" : "v\(addon.manifest.version)")
                    }
                    Button("Reload Addons and Library") {
                        Task { await model.refresh() }
                    }
                } header: {
                    Text("Addons")
                } footer: {
                    Text("Install or remove addons in any Stremio app or at web.stremio.com.")
                }

                Section {
                    Button("Sign Out and Remove Profile", role: .destructive) { confirmSignOut = true }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { badCount = BadStreams.count }
        .confirmationDialog("Sign out and remove \(model.activeProfile?.name ?? "this profile")?",
                            isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { model.signOut() }
        }
    }
}

/// TMDB key for recommendations. Typing is easiest from an iPhone's Apple TV keyboard prompt.
struct TVTMDBKeySection: View {
    @State private var key = TMDB.apiKey ?? ""
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        Section {
            TextField("TMDB API key or read access token", text: $key)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(checking ? "Checking…" : (TMDB.isConfigured ? "Update Key" : "Save Key")) {
                Task {
                    checking = true
                    status = await TMDB.validate(key) ? "Key works. Recommendations will show on Home."
                                                      : "TMDB didn't accept that key."
                    checking = false
                }
            }
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            if TMDB.isConfigured {
                Button("Remove Key", role: .destructive) {
                    TMDB.apiKey = nil
                    key = ""
                    status = "Removed."
                }
            }
        } header: {
            Text("Recommendations")
        } footer: {
            Text(status ?? "Recommended for You, Trending Now and Because You Watched come from The Movie Database. Get a free key at themoviedb.org → Settings → API.")
        }
    }
}
