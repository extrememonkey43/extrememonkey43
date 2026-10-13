import SwiftUI

struct SettingsView: View {
    struct Status {
        var maximumHz: Int
        var measuredHz: Double?
        var near60Removed: Bool
        var codecsEnabled: [String]
        var lastRequest: String?
    }

    let status: Status
    var onDone: () -> Void
    var onClearData: () -> Void

    @AppStorage(SettingsKey.fps) private var fps = BrowserSettings.defaults.fps
    @AppStorage(SettingsKey.resolution) private var resolutionID = BrowserSettings.defaults.resolutionID
    @AppStorage(SettingsKey.identity) private var identity = BrowserSettings.defaults.identity
    @AppStorage(SettingsKey.serverProfile) private var serverProfile = BrowserSettings.defaults.serverProfile
    @AppStorage(SettingsKey.lockDisplay) private var lockDisplay = BrowserSettings.defaults.lockDisplay
    @AppStorage(SettingsKey.unlockWebKit) private var unlockWebKit = BrowserSettings.defaults.unlockWebKit
    @AppStorage(SettingsKey.modernCodecs) private var modernCodecs = BrowserSettings.defaults.modernCodecs
    @AppStorage(SettingsKey.showHUD) private var showHUD = BrowserSettings.defaults.showHUD
    @AppStorage(SettingsKey.showMenuButton) private var showMenuButton = BrowserSettings.defaults.showMenuButton
    @AppStorage(SettingsKey.menuCorner) private var menuCorner = BrowserSettings.defaults.menuCorner
    @AppStorage(SettingsKey.homeURL) private var homeURL = BrowserSettings.defaults.homeURL

    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                streamSection
                identitySection
                displaySection
                interfaceSection
                statusSection
                advancedSection
                tipsSection
            }
            .navigationTitle("Sedef")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti", action: onDone)
                }
            }
        }
    }

    private var streamSection: some View {
        Section {
            Picker("Kare hızı", selection: $fps) {
                Text("120 FPS").tag(120)
                Text("60 FPS").tag(60)
                Text("GFN'ye bırak").tag(0)
            }
            Picker("Çözünürlük", selection: $resolutionID) {
                ForEach(StreamResolution.all) { resolution in
                    Text(resolution.title).tag(resolution.id)
                }
            }
        } header: {
            Text("Akış")
        } footer: {
            Text("Bu değerler GeForce NOW'un sunucuya gönderdiği oturum isteğine yazılır. 120 FPS'i sunucu ancak üyelik paketin izin veriyorsa (genelde Ultimate) verir. Değişiklikler sayfayı yeniden yükler.")
        }
    }

    private var identitySection: some View {
        Section {
            Picker("Tarayıcı kimliği", selection: $identity) {
                ForEach(BrowserIdentity.allCases) { identity in
                    Text(identity.title).tag(identity)
                }
            }
            Picker("Sunucu profili", selection: $serverProfile) {
                ForEach(ServerProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
        } header: {
            Text("Kimlik")
        } footer: {
            Text("Tarayıcı kimliği sitenin gördüğüdür: GeForce NOW iPad'de yalnızca ana ekrana eklenmiş uygulamadan oyun açar, \"iPad · ana ekran uygulaması\" bunu sağlar. Sunucu profili ise yalnızca oyun başlarken sunucuya giden istekteki cihaz bilgisidir; sunucu iPad/Safari'ye 60 FPS'ten fazlasını vermez. Oyun açılmazsa veya görüntü gelmezse bir alt seçeneği dene.")
        }
    }

    private var displaySection: some View {
        Section {
            Toggle("Ekranı \(status.maximumHz) Hz'de tut", isOn: $lockDisplay)
            Toggle("WebKit 60 FPS sınırını kaldır", isOn: $unlockWebKit)
            Toggle("H.265 / AV1 kodeklerini aç (deneysel)", isOn: $modernCodecs)
        } header: {
            Text("Ekran ve motor")
        } footer: {
            Text("ProMotion boşta kalınca kendini düşürür; kilit, oyun boyunca paneli en yüksek hızda tutar (biraz daha fazla pil harcar). WebKit sınırı Safari'deki \"Prefer Page Rendering Updates near 60fps\" anahtarının aynısıdır.")
        }
    }

    private var interfaceSection: some View {
        Section("Arayüz") {
            Toggle("İstatistik göstergesi (HUD)", isOn: $showHUD)
            Toggle("Menü düğmesi", isOn: $showMenuButton)
            Picker("Düğmenin yeri", selection: $menuCorner) {
                ForEach(MenuCorner.allCases) { corner in
                    Text(corner.title).tag(corner)
                }
            }
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("Ekranın en yüksek hızı", value: "\(status.maximumHz) Hz")
            LabeledContent("Şu an ölçülen", value: status.measuredHz.map { "\(Int($0.rounded())) Hz" } ?? "—")
            LabeledContent("WebKit 60 FPS sınırı", value: status.near60Removed ? "Kaldırıldı" : (unlockWebKit ? "Bu sürümde bulunamadı" : "Açık"))
            if modernCodecs {
                LabeledContent("Açılan kodekler", value: status.codecsEnabled.isEmpty ? "Bulunamadı" : status.codecsEnabled.map(codecName).joined(separator: ", "))
            }
            LabeledContent("Son oturum isteği", value: status.lastRequest ?? "Henüz yok")
        } header: {
            Text("Durum")
        } footer: {
            Text("\"Şu an ölçülen\" 60 Hz gösteriyorsa: Düşük Güç Modu'nu kapat ve Ayarlar ▸ Erişilebilirlik ▸ Hareket ▸ \"Kare Hızını Sınırla\" seçeneğinin kapalı olduğundan emin ol.")
        }
    }

    private var advancedSection: some View {
        Section("Gelişmiş") {
            TextField("Başlangıç adresi", text: $homeURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Varsayılan adrese dön") {
                homeURL = BrowserSettings.defaultHomeURL
            }
            Button("Site verilerini sil (oturumu kapatır)", role: .destructive) {
                confirmClear = true
            }
            .confirmationDialog("Çerezler ve site verileri silinsin mi?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Sil", role: .destructive, action: onClearData)
            }
        }
    }

    private var tipsSection: some View {
        Section("Kısayollar") {
            Text("Üç parmakla basılı tut: bu ekran")
            Text("⌘ , : ayarlar  ·  ⇧⌘ R : yenile  ·  ⇧⌘ I : istatistikler")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func codecName(_ key: String) -> String {
        key.replacingOccurrences(of: "WebRTC", with: "").replacingOccurrences(of: "CodecEnabled", with: "")
    }
}
