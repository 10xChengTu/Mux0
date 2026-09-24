import SwiftUI

struct UpdateSectionView: View {
    let theme: AppTheme
    let updateStore: UpdateStore

    @Environment(\.locale) private var locale

    private var isDebug: Bool {
        !SparkleBridge.shared.isActive
    }
    /// This fork's Release builds are compiled with `MUX0_UPDATES_DISABLED`:
    /// the upstream appcast belongs to the original author's repo, and a new
    /// upstream release would silently replace the fork on the user's machine.
    /// No Sparkle call site is compiled in (see SparkleBridge — the framework is
    /// still linked and embedded, just never used), so explain it instead of
    /// leaving a "Check for Updates" button that can only fail.
    private var isUpdatesDisabledAtBuild: Bool {
        SparkleBridge.updatesDisabledAtBuildTime
    }

    var body: some View {
        Form {
            // 当前版本 —— 始终显示在最上方，与其它 section 首行一致。
            LabeledContent(String(localized: L10n.Settings.Update.currentVersion.withLocale(locale))) {
                Text("v\(updateStore.currentVersion)")
                    .font(Font(DT.Font.body).monospacedDigit())
                    .foregroundColor(Color(theme.textSecondary))
            }

            // 主状态行：每个 UpdateState 各自的 label + 右侧控件。
            statusRow

            // 仅 .updateAvailable 时额外出现的 release notes section。
            // Form(.grouped) 里 Section 会变成一个圆角分组，和其它 section
            // 的分组视觉一致。
            if case .updateAvailable(_, let notes) = updateStore.state,
               let notes = notes, !notes.isEmpty {
                Section(String(localized: L10n.Settings.Update.releaseNotes.withLocale(locale))) {
                    ScrollView {
                        Text(notes)
                            .font(Font(DT.Font.small))
                            .foregroundColor(Color(theme.textSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, DT.Space.xxs)
                    }
                    .frame(maxHeight: 128)
                }
            }

            // 仅 .updateAvailable 时额外出现的操作按钮行。
            if case .updateAvailable = updateStore.state {
                LabeledContent(String(localized: L10n.Settings.Update.action.withLocale(locale))) {
                    HStack(spacing: DT.Space.sm) {
                        Button(String(localized: L10n.Settings.Update.downloadInstall.withLocale(locale))) {
                            SparkleBridge.shared.downloadAndInstall()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(String(localized: L10n.Settings.Update.skipThisVersion.withLocale(locale))) {
                            SparkleBridge.shared.skipVersion()
                        }

                        Button(String(localized: L10n.Settings.Update.dismiss.withLocale(locale))) {
                            SparkleBridge.shared.dismiss()
                        }
                    }
                }
            }

            // Debug 构建 / 关闭了上游更新源的构建：显式说明自动更新被禁用，
            // 行风格与其它 LabeledContent 对齐。两者互斥——fork 构建的 Release
            // 也走 isActive == false，但那不是 "Debug build"，说清楚原因。
            if isUpdatesDisabledAtBuild {
                LabeledContent(String(localized: L10n.Settings.Update.updatesRow.withLocale(locale))) {
                    Text(L10n.Settings.Update.updatesDisabledFork)
                        .font(Font(DT.Font.small))
                        .foregroundColor(Color(theme.textTertiary))
                }
            } else if isDebug {
                LabeledContent(String(localized: L10n.Settings.Update.debugBuild.withLocale(locale))) {
                    Text(L10n.Settings.Update.debugDisabled)
                        .font(Font(DT.Font.small))
                        .foregroundColor(Color(theme.textTertiary))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Status Row

    @ViewBuilder
    private var statusRow: some View {
        switch updateStore.state {
        case .idle:
            LabeledContent(String(localized: L10n.Settings.Update.status.withLocale(locale))) {
                Button(String(localized: L10n.Settings.Update.checkForUpdates.withLocale(locale))) {
                    SparkleBridge.shared.checkForUpdates(silently: false)
                }
                .disabled(isDebug)
            }

        case .checking:
            LabeledContent(String(localized: L10n.Settings.Update.status.withLocale(locale))) {
                HStack(spacing: DT.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Settings.Update.checking)
                        .foregroundColor(Color(theme.textSecondary))
                }
            }

        case .upToDate:
            LabeledContent(String(localized: L10n.Settings.Update.status.withLocale(locale))) {
                HStack(spacing: DT.Space.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(theme.success))
                    Text(L10n.Settings.Update.upToDate)
                        .foregroundColor(Color(theme.textPrimary))
                }
            }

        case .updateAvailable(let version, _):
            LabeledContent(String(localized: L10n.Settings.Update.availableUpdate.withLocale(locale))) {
                Text(L10n.Settings.Update.versionNumber(version))
                    .font(Font(DT.Font.bodyB))
                    .foregroundColor(Color(theme.textPrimary))
            }

        case .downloading(let progress):
            LabeledContent(String(localized: L10n.Settings.Update.downloading.withLocale(locale))) {
                HStack(spacing: DT.Space.sm) {
                    ProgressView(value: progress)
                        .tint(Color(theme.accent))
                        .frame(minWidth: 120)
                    Text("\(Int(progress * 100))%")
                        .font(Font(DT.Font.body).monospacedDigit())
                        .frame(width: DT.Space.xl * 2, alignment: .trailing)
                }
            }

        case .readyToInstall:
            LabeledContent(String(localized: L10n.Settings.Update.status.withLocale(locale))) {
                HStack(spacing: DT.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Settings.Update.installing)
                        .foregroundColor(Color(theme.textPrimary))
                }
            }

        case .error(let message):
            // 错误态拆两行，视觉上和常规 LabeledContent 对齐：第一行描述，第二行 Retry。
            LabeledContent(String(localized: L10n.Settings.Update.error.withLocale(locale))) {
                Text(message)
                    .font(Font(DT.Font.small))
                    .foregroundColor(Color(theme.danger))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
            }
            LabeledContent("") {
                Button(String(localized: L10n.Settings.Update.retry.withLocale(locale))) {
                    SparkleBridge.shared.retry()
                }
            }
        }
    }
}
