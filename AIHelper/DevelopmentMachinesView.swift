import SwiftUI

// MARK: - Window View

/// Full window listing every host found in `~/.ssh/config`.
struct DevelopmentMachinesView: View {
    @StateObject private var viewModel = DevelopmentMachinesViewModel()

    var body: some View {
        DevelopmentMachinesListView(viewModel: viewModel)
            .frame(minWidth: 480, minHeight: 360)
    }
}

// MARK: - Shared List View

/// Header + scrollable host list + footer, driven by an injected view model.
/// Shared by the standalone window (`DevelopmentMachinesView`) and the
/// Development Machines section inside Settings.
struct DevelopmentMachinesListView: View {
    @ObservedObject var viewModel: DevelopmentMachinesViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding()

            Divider()

            if viewModel.hosts.isEmpty {
                emptyView
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(viewModel.hosts) { host in
                            DevelopmentMachineRowView(
                                host: host,
                                isCopied: viewModel.copiedItemId == host.id,
                                isScreenshotTarget: viewModel.isScreenshotTarget(host),
                                onCopySSH: { viewModel.copySSHCommand(for: host) },
                                onOpenTerminal: { viewModel.openTerminalWithSSH(for: host) },
                                onOpenBrowser: { viewModel.openInBrowser(for: host) },
                                onToggleScreenshotTarget: { viewModel.toggleScreenshotTarget(host) }
                            )
                        }
                    }
                    .padding()
                }

                Divider()

                footerView
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
    }

    private var headerView: some View {
        HStack {
            Label("Development Machines", systemImage: "desktopcomputer")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Reload from ~/.ssh/config")
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "desktopcomputer")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No hosts found")
                .font(.headline)

            Text("Add hosts to ~/.ssh/config to see them here.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerView: some View {
        HStack {
            Text("\(viewModel.hosts.count) host\(viewModel.hosts.count == 1 ? "" : "s") from ~/.ssh/config")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: - Row View

struct DevelopmentMachineRowView: View {
    let host: SSHHost
    let isCopied: Bool
    let isScreenshotTarget: Bool
    let onCopySSH: () -> Void
    let onOpenTerminal: () -> Void
    let onOpenBrowser: () -> Void
    let onToggleScreenshotTarget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundColor(.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.alias)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)

                    if isScreenshotTarget {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.accentColor)
                            .help("Default screenshot transfer target")
                    }
                }

                HStack(spacing: 8) {
                    if !host.displayHost.isEmpty {
                        Label(host.displayHost, systemImage: "network")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if !host.user.isEmpty {
                        Label(host.user, systemImage: "person")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if isCopied {
                    Text("Copied!")
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
                } else {
                    Button(action: onCopySSH) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("Copy ssh command")
                }

                Button(action: onOpenTerminal) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Open in Terminal")

                Button(action: onOpenBrowser) {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Open in Browser")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
        .contextMenu {
            Button(isScreenshotTarget ? "Unset Screenshot Target" : "Set as Screenshot Target",
                   action: onToggleScreenshotTarget)
        }
    }
}

// MARK: - Inline View (menu popover)

/// Compact list of dev machines shown inline in the main menu-bar popover.
struct DevelopmentMachinesInlineView: View {
    @ObservedObject var viewModel: DevelopmentMachinesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "desktopcomputer")
                    .foregroundColor(.accentColor)
                Text("Development Machines")
                    .font(.caption)
                    .fontWeight(.medium)

                Spacer()

                Button(action: { viewModel.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Reload")
            }

            if viewModel.hosts.isEmpty {
                Text("No hosts in ~/.ssh/config")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                let listHeight = min(CGFloat(viewModel.hosts.count) * 36, 200)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(viewModel.hosts) { host in
                            CompactDevMachineRow(host: host, viewModel: viewModel)
                        }
                    }
                }
                .frame(height: listHeight)
                .scrollIndicators(.visible)
            }
        }
    }
}

struct CompactDevMachineRow: View {
    let host: SSHHost
    @ObservedObject var viewModel: DevelopmentMachinesViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Text(host.alias)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            if viewModel.copiedItemId == host.id {
                Text("Copied!")
                    .font(.caption2)
                    .foregroundColor(.green)
            } else {
                Button(action: { viewModel.copySSHCommand(for: host) }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Copy ssh command")
            }

            Button(action: { viewModel.openTerminalWithSSH(for: host) }) {
                Image(systemName: "terminal")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Open in Terminal")

            Button(action: { viewModel.openInBrowser(for: host) }) {
                Image(systemName: "globe")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Open in Browser")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
    }
}
