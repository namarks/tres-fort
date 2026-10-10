import CoreImage.CIFilterBuiltins
import SwiftUI

/// The QR shortcut and the visible Today action open the same confirmation.
/// Opening a URL never opts an account in or starts a workout.
struct StationPhoneSetupView: View {
    @ObservedObject var auth: AuthModel
    @ObservedObject var link: StationLinkController
    let onDone: () -> Void
    private let accountID: String?
    private let epoch: UInt64
    @AppStorage(StationLink.enabledAccountDefaultsKey) private var enabledAccount = ""

    init(auth: AuthModel, link: StationLinkController, onDone: @escaping () -> Void) {
        self.auth = auth
        self.link = link
        self.onDone = onDone
        accountID = auth.userID
        epoch = auth.featureSessionEpoch
    }

    private var canConnect: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && !auth.isReviewAccount
            && auth.isCurrentFeatureSession(accountID: accountID, epoch: epoch)
    }
    private var enabled: Bool { StationLink.isEnabled(storedAccount: enabledAccount, accountID: accountID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "ipad.landscape")
                        .font(.system(size: 42)).foregroundStyle(Theme.accent)
                    Text(link.isConnected && enabled ? "IPAD CONNECTED" : "YOUR WORKOUT, ON IPAD")
                        .font(Theme.display(36)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if UIDevice.current.userInterfaceIdiom != .phone {
                        Text("Open this setup code on your iPhone. On this iPad, open Station from Today.")
                    } else {
                        Text("Open Station on your iPad and sign in to the same Très Fort account. Your iPhone runs the workout; your iPad shows each exercise, target and rest timer.")
                        Text("We’ll remember this choice. Next time, open Très Fort on your iPhone and Station on your iPad to reconnect.")
                            .foregroundStyle(Theme.muted)
                        if StationLink.cameraCountingAvailable {
                            Text("If you enable camera tracking on the iPad, supported counted sets log on your iPhone with Undo. Keep the workout open while training.")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                        if enabled {
                            Label(connectionMessage, systemImage: link.isConnected ? "checkmark.circle.fill" : "iphone.and.arrow.forward")
                                .foregroundStyle(link.isConnected ? Theme.accent : Theme.text)
                                .accessibilityIdentifier("station.phoneStatus")
                            if link.isConnected {
                                Button("Continue", action: onDone)
                                    .buttonStyle(WorkoutPrimaryButtonStyle())
                            } else {
                                Button("Try again") { if canConnect { link.retryConnection() } }
                                    .buttonStyle(WorkoutPrimaryButtonStyle())
                                    .accessibilityIdentifier("station.phoneRetry")
                            }
                            Button("Turn off iPad display") {
                                guard canConnect else { return }
                                enabledAccount = ""
                                link.stop()
                            }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("station.phoneDisconnect")
                        } else {
                            Button("Connect iPad") {
                                guard canConnect, let accountID else { return }
                                enabledAccount = accountID
                                link.retryConnection()
                            }
                            .buttonStyle(WorkoutPrimaryButtonStyle())
                            .disabled(!canConnect)
                            .accessibilityIdentifier("station.phoneConnect")
                        }
                        StationConnectionHelp()
                    }
                }
                .font(.body)
                .foregroundStyle(Theme.text)
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background)
            .navigationTitle("iPad display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) } }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private var connectionMessage: String {
        if link.needsKey { return "Connect this iPhone to the internet, then try again." }
        switch link.connection {
        case .connected(let name): return "Connected to \(name). Start or resume your workout when you’re ready."
        case .unavailable: return "Couldn’t start the local connection. Check Local Network access in Settings, then try again."
        case .off, .searching: return "Looking for your iPad. Open Station on it and tap Connect iPhone."
        }
    }
}

struct StationSetupCode: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("First time? Scan with your iPhone camera.")
                .font(.headline)
            let layout = sizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 24))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            layout {
                if let image = Self.image() {
                    Image(uiImage: image).interpolation(.none).resizable()
                        .scaledToFit().frame(width: 176, height: 176)
                        .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("iPhone setup QR code")
                        .accessibilityIdentifier("station.setupCode")
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Open the Très Fort link, then tap Connect iPad. You only need to set this up once.")
                    Text("You can also open Très Fort on your iPhone and tap iPad display at the top of Today or your workout.")
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func image() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(StationLink.setupURL.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct StationConnectionHelp: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        DisclosureGroup("Connection help") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keep both apps open nearby, with Wi-Fi and Bluetooth on. Both devices must be signed in to the same Très Fort account.")
                Text("Allow Très Fort under Settings → Privacy & Security → Local Network on both devices.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("station.connectionSettings")
            }
            .font(.body).foregroundStyle(Theme.muted)
            .padding(.top, 12)
            .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Theme.accent)
        .accessibilityIdentifier("station.connectionHelp")
    }
}
