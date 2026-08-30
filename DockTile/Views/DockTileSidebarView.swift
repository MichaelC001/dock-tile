//
//  DockTileSidebarView.swift
//  DockTile
//
//  Sidebar with list of dock tile configurations
//  Swift 6 - Strict Concurrency
//

import SwiftUI

struct DockTileSidebarView: View {
    @EnvironmentObject private var configManager: ConfigurationManager

    /// Drives the whole detail column (tiles + inline Settings). Owned by the parent so the
    /// detail pane and the sidebar stay in lock-step. See `SidebarSelection`.
    @Binding var selection: SidebarSelection?

    /// Invoked when the toolbar + is pressed. The parent decides whether to show the Smart Add
    /// sheet (if the engine has suggestions) or fall through to a blank tile — see
    /// `DockTileConfigurationView`. Kept as a closure so the sheet stays hosted in the parent.
    var onAdd: () -> Void
    /// Same flow as `onAdd`, but from the zero-tiles row rather than the toolbar +, so the
    /// diagnostics trace can tell the two affordances apart.
    var onAddFromRow: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section(AppStrings.Sidebar.tilesSection) {
                if configManager.configurations.isEmpty {
                    // At zero tiles this row IS the only way to add one — the toolbar + stays hidden
                    // until a tile exists (see `addButton`). It also replaces the old inert
                    // "No Tiles" placeholder as the escape route out of a Settings pane: with no
                    // tile rows to click back to, the user would otherwise be stranded there.
                    Button(action: onAddFromRow) {
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 24, height: 24)
                                .foregroundStyle(.secondary)
                            Text(AppStrings.Button.addATile)
                                .font(.system(size: 13))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .tag(SidebarSelection.tilesPlaceholder)
                } else {
                    ForEach(configManager.configurations) { config in
                        ConfigurationRow(config: config)
                            .tag(SidebarSelection.tile(config.id))
                            .contextMenu {
                                ConfigurationContextMenu(config: config)
                            }
                    }
                }
            }

            // Settings — inline panes that replace the old detached ⌘, window.
            Section(AppStrings.Sidebar.settingsSection) {
                SettingsRow(
                    title: AppStrings.Settings.general,
                    systemName: PaneIcon.general.systemName,
                    tint: PaneIcon.general.tint
                )
                .tag(SidebarSelection.settings(.general))

                SettingsRow(
                    title: AppStrings.Settings.popover,
                    systemName: PaneIcon.popover.systemName,
                    tint: PaneIcon.popover.tint
                )
                .tag(SidebarSelection.settings(.popover))

                SettingsRow(
                    title: AppStrings.Settings.dockLock,
                    systemName: PaneIcon.dockLock.systemName,
                    tint: PaneIcon.dockLock.tint
                )
                .tag(SidebarSelection.settings(.dockLock))
            }

            Section(AppStrings.Sidebar.dockTileSection) {
                SettingsRow(title: AppStrings.About.title, systemName: PaneIcon.about.systemName, tint: PaneIcon.about.tint)
                    .tag(SidebarSelection.settings(.about))
            }
        }
        // `.sidebar` style gives the section headers their native treatment and the tile-row
        // selection highlight.
        .listStyle(.sidebar)
        // The ONLY placement that actually suppresses the toggle: applied at the NavigationSplitView
        // level it still rendered. It must stay on the sidebar column's own content.
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            // Hidden until the first tile exists: at zero tiles the "Add a Tile…" row above is the
            // single add affordance, so first run offers exactly one way in rather than three.
            if !configManager.configurations.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("addTileButton")
                    .accessibilityLabel(AppStrings.Button.addATile)
                    .disabled(!configManager.canCreateNewTile)
                    .help(configManager.canCreateNewTile
                        ? AppStrings.Tooltip.createNewTile
                        : AppStrings.Tooltip.editFirst)
                }
            }
        }
    }
}

// MARK: - Settings Row

/// A sidebar row for an inline Settings pane. Mirrors `ConfigurationRow`'s layout (24pt squircle
/// badge + 13pt label) so Settings entries sit visually flush with the tiles above them.
struct SettingsRow: View {
    let title: String
    let systemName: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            SettingsBadgeIcon(systemName: systemName, tint: tint)

            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

/// A squircle badge matching the tile icon look (`DockTileIconPreview`): continuous rounded
/// rect, top-to-bottom gradient, white SF Symbol, subtle inner glass stroke, and the same
/// Liquid-Glass depth (top sheen + glyph contact shadow) as the tiles. Settings badges always
/// render in the colourful Default style, so the depth seam is read with `.defaultStyle`.
struct SettingsBadgeIcon: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 24

    private var cornerRadius: CGFloat { size * 0.225 }

    private var glyphShadow: IconDepthMetrics.GlyphShadow? {
        IconDepthMetrics.glyphShadow(style: .defaultStyle, iconType: .sfSymbol, nominalSize: size)
    }

    private var glyphForeground: AnyShapeStyle {
        if let darken = IconDepthMetrics.glyphBottomDarken(style: .defaultStyle, iconType: .sfSymbol, nominalSize: size) {
            return AnyShapeStyle(
                LinearGradient(colors: [.white, Color.white.darkened(by: darken)], startPoint: .top, endPoint: .bottom)
            )
        }
        return AnyShapeStyle(Color.white)
    }

    var body: some View {
        let sheenAlpha = IconDepthMetrics.surfaceSheenAlpha(style: .defaultStyle, nominalSize: size)

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(IconDepthMetrics.strokeOpacity(style: .defaultStyle)),
                    lineWidth: IconDepthMetrics.strokeLineWidth(nominalSize: size)
                )

            if sheenAlpha > 0 {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(sheenAlpha), location: 0),
                                .init(color: .clear, location: IconDepthMetrics.surfaceSheenHeightFraction)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(glyphForeground)
                .shadow(
                    color: glyphShadow.map { Color.black.opacity($0.blackAlpha) } ?? .clear,
                    radius: glyphShadow?.blur ?? 0,
                    y: glyphShadow?.offset ?? 0
                )
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Configuration Row

struct ConfigurationRow: View {
    @EnvironmentObject private var configManager: ConfigurationManager
    let config: DockTileConfiguration

    var body: some View {
        HStack(spacing: 12) {
            // Mini icon preview (24×24pt) - uses same component as other previews
            DockTileIconPreview.fromConfig(config, size: 24)

            // The COMMITTED name, not the stored one: a rename in the editor re-titles the live
            // preview immediately but only reaches this row on Add to Dock / Update / Done.
            Text(configManager.displayName(for: config.id))
                .font(.system(size: 13))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Context Menu

struct ConfigurationContextMenu: View {
    @EnvironmentObject private var configManager: ConfigurationManager
    let config: DockTileConfiguration

    var body: some View {
        Button(AppStrings.Button.duplicate) {
            DiagnosticsLog.shared.ui("Sidebar context menu → Duplicate '\(config.name)'")
            configManager.duplicateConfiguration(config)
        }

        Divider()

        Button(AppStrings.Button.delete, role: .destructive) {
            DiagnosticsLog.shared.ui("Sidebar context menu → Delete '\(config.name)'")
            configManager.deleteConfiguration(config.id)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationSplitView {
        DockTileSidebarView(selection: .constant(nil), onAdd: {}, onAddFromRow: {})
            .environmentObject({
                let manager = ConfigurationManager()
                manager.createConfiguration()
                return manager
            }())
    } detail: {
        Text(AppStrings.Empty.detail)
    }
}
