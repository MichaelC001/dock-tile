//
//  AboutView.swift
//  DockTile
//
//  The About pane (v2): lives in the sidebar under "Dock Tile" — the only home of Software Update.
//  Swift 6 - Strict Concurrency
//

import SwiftUI

/// Links the pane opens. `feedback` comes from Info.plist `DTFeedbackEmail` (mailto:) when set,
/// otherwise the website — never a hard-coded address.
enum AboutLinks {
    static let website = URL(string: "https://docktile.rkarthik.co")!
    static let studio  = URL(string: "https://happymachines.company/")!
    static let spades  = URL(string: "https://spadesaudio.com/")!
    static var feedback: URL {
        guard let email = Bundle.main.object(forInfoDictionaryKey: "DTFeedbackEmail") as? String,
              !email.isEmpty else { return website }
        // Build through URLComponents rather than interpolating: the address comes from Info.plist,
        // and an unencoded subject or a stray character would silently yield a nil URL.
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [URLQueryItem(name: "subject", value: "Dock Tile feedback")]
        return components.url ?? website
    }
}

struct AboutPaneView: View {
    @EnvironmentObject private var configManager: ConfigurationManager
    @EnvironmentObject private var updateController: UpdateController

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    // One grouped Form (a Form is List-backed and will not size itself inside a ScrollView): the hero
    // rides as a full-bleed, clear-background first row.
    var body: some View {
        Form {
                    Section {
                        hero
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        LabeledContent {
                            Button(AppStrings.Button.checkForUpdates) {
                                DiagnosticsLog.shared.ui("About → Check for Updates")
                                updateController.checkForUpdates()
                            }
                            .disabled(!updateController.canCheckForUpdates)
                        } label: {
                            Text(AppStrings.appName)
                            Text(AppStrings.About.version(AppEnvironment.appVersion))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        LabeledContent(AppStrings.About.website) {
                            Link("docktile.rkarthik.co", destination: AboutLinks.website)
                        }
                    }
                    Section {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppStrings.About.feedbackTitle)
                            Text(AppStrings.About.feedbackBody).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Button {
                                DiagnosticsLog.shared.ui("About → Send Feedback")
                                NSWorkspace.shared.open(AboutLinks.feedback)
                            } label: { Label(AppStrings.About.sendFeedback, systemImage: "envelope") }
                            .frame(maxWidth: .infinity)
                            Button {
                                DiagnosticsLog.shared.ui("About → Copy Diagnostics")
                                DiagnosticsLog.shared.copyToPasteboard()
                            } label: { Label(AppStrings.Menu.copyDiagnostics, systemImage: "doc.text") }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    Section {
                        studioRow(icon: "face.smiling", tint: .orange, title: AppStrings.About.studioTitle,
                                  subtitle: AppStrings.About.studioSubtitle) {
                            Link("happymachines.company", destination: AboutLinks.studio)
                        }
                        studioRow(icon: "suit.spade.fill", tint: .black, title: AppStrings.About.spadesTitle,
                                  subtitle: AppStrings.About.spadesSubtitle) {
                            Button(AppStrings.About.learnMore) { NSWorkspace.shared.open(AboutLinks.spades) }
                        }
                    } header: {
                        Text(AppStrings.About.alsoFrom)
                    } footer: {
                        Text(copyright)
                            .font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
        }
        .formStyle(.grouped)
        .paneTitleBand(AppStrings.About.title)
    }

    /// The product in context: the user's first three tiles (or the defaults) on a Dock strip.
    private var hero: some View {
        let tiles = Array(configManager.configurations.prefix(3))
        return HStack(spacing: 10) {
            if tiles.isEmpty {
                ForEach([TintColor.blue, .purple, .pink], id: \.self) { tint in
                    DockTileIconPreview(tintColor: tint, iconType: .sfSymbol, iconValue: "folder.fill",
                                        iconScale: ConfigurationDefaults.iconScale,
                                        iconWeight: ConfigurationDefaults.iconWeight, size: 48)
                }
            } else {
                ForEach(tiles) { DockTileIconPreview.fromConfig($0, size: 48) }
            }
            Divider().frame(height: 40)
            Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 48, height: 48)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(StudioCanvasBackgroundView())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppStrings.appName)
    }

    private func studioRow<Trailing: View>(icon: String, tint: Color, title: String, subtitle: String,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        LabeledContent {
            trailing()
        } label: {
            HStack(spacing: 12) {
                SettingsBadgeIcon(systemName: icon, tint: tint, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
