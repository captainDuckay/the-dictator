import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settingsModule: SettingsModule
    let onAppear: () -> Void
    let onDisappear: () -> Void

    @State private var isShowingCustomModelImporter = false

    var body: some View {
        let snapshot = settingsModule.snapshot

        Form {
            Section("Hotkeys") {
                LabeledContent("Push-to-talk") {
                    HotkeyRecorderField(
                        value: binding(\.pushToTalkHotkey),
                        placeholder: "Press shortcut"
                    )
                    .frame(width: 220)
                }

                LabeledContent("Paste last transcript") {
                    HotkeyRecorderField(
                        value: binding(\.pasteLastTranscriptHotkey),
                        placeholder: "Press shortcut"
                    )
                    .frame(width: 220)
                }

                Text("Shortcuts can be modifier-only (for example Right Option) or modifier + key combinations (for example Control + 8, Option + F8).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                TextField("Backend", text: binding(\.backendType))

                if let hint = snapshot.modelManagerOnboardingHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(snapshot.workflowRuntimePreflightDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let runtimeIssue = snapshot.workflowRuntimeIssue {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(runtimeIssue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)

                        HStack {
                            if let recoveryTitle = snapshot.runtimeRecoveryActionTitle {
                                Button(recoveryTitle) {
                                    settingsModule.performRuntimeRecoveryAction()
                                }
                                .font(.caption)
                            }

                            Button("Re-check Runtime") {
                                settingsModule.refreshInstalledModels()
                                settingsModule.refreshModelCatalog(force: true)
                            }
                            .font(.caption)
                        }
                    }
                }

                if snapshot.isUsingFallbackCatalog {
                    Label("Using fallback model catalog", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(settingsModule.modelManagerCatalogRefreshDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(snapshot.modelManagerAvailableModels) { descriptor in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(settingsModule.modelLabel(for: descriptor))
                                .fontWeight(snapshot.settings.selectedModelID == descriptor.id && !snapshot.settings.useCustomModelPath ? .semibold : .regular)
                            Spacer()
                            Text(settingsModule.modelStatus(for: descriptor.id))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(settingsModule.modelResourceHint(for: descriptor))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(settingsModule.modelVersionHint(for: descriptor))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Use") {
                                settingsModule.selectModel(id: descriptor.id)
                            }
                            .disabled(!settingsModule.isModelInstalled(descriptor.id))

                            if settingsModule.isModelInstalled(descriptor.id) {
                                if settingsModule.isModelUpdateAvailable(descriptor.id) {
                                    Button("Update") {
                                        settingsModule.downloadModel(id: descriptor.id)
                                    }
                                    .disabled(descriptor.downloadURL == nil)
                                }

                                if settingsModule.canDeleteModel(descriptor.id) {
                                    Button("Delete") {
                                        settingsModule.deleteModel(id: descriptor.id)
                                    }
                                }
                            } else if case .downloading = snapshot.modelManagerDownloadStates[descriptor.id] {
                                Button("Cancel") {
                                    settingsModule.cancelModelDownload(id: descriptor.id)
                                }
                            } else {
                                Button("Download") {
                                    settingsModule.downloadModel(id: descriptor.id)
                                }
                                .disabled(descriptor.downloadURL == nil)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let modelManagerStatusMessage = snapshot.modelManagerStatusMessage {
                    Text(modelManagerStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Refresh Model Catalog") {
                        settingsModule.refreshModelCatalog(force: true)
                    }
                    .disabled(snapshot.modelManagerIsRefreshingCatalog)

                    if snapshot.modelManagerIsRefreshingCatalog {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Toggle("Use custom local model (Advanced)", isOn: binding(\.useCustomModelPath))
                if snapshot.settings.useCustomModelPath {
                    TextField("Custom model path", text: binding(\.customModelPath))

                    Button("Choose Custom Model File…") {
                        isShowingCustomModelImporter = true
                    }
                    .fileImporter(
                        isPresented: $isShowingCustomModelImporter,
                        allowedContentTypes: [.data],
                        allowsMultipleSelection: false
                    ) { result in
                        guard case .success(let urls) = result, let url = urls.first else {
                            return
                        }

                        settingsModule.updateSetting(\.customModelPath, url.path)
                        settingsModule.updateSetting(\.useCustomModelPath, true)
                    }
                }

                Toggle("Auto-detect language", isOn: binding(\.languageAutoDetect))
                TextField("Preferred language", text: binding(\.preferredLanguage))
                Toggle("Polished output", isOn: binding(\.polishedOutputEnabled))

                LabeledContent("Capabilities") {
                    Text(snapshot.backendCapabilitiesDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Audio") {
                Toggle("Audio cues", isOn: binding(\.audioCuesEnabled))

                Picker("Input microphone", selection: audioInputSelectionBinding) {
                    ForEach(snapshot.audioInputOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }

                Text(snapshot.audioInputStatusDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Refresh Audio Inputs") {
                    settingsModule.refreshAudioInputDevices()
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    Text(snapshot.microphonePermissionStatus)
                }

                LabeledContent("Accessibility") {
                    Text(snapshot.accessibilityPermissionStatus)
                }

                Button("Refresh Permission Status") {
                    settingsModule.refreshPermissionStatuses()
                }

                Button("Request Microphone Permission") {
                    settingsModule.requestMicrophonePermission()
                }

                Button("Open Microphone Privacy Settings") {
                    settingsModule.openMicrophonePrivacySettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480)
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
    }

    private var audioInputSelectionBinding: Binding<String> {
        Binding {
            settingsModule.snapshot.selectedAudioInputOptionID
        } set: { newValue in
            settingsModule.selectAudioInputOption(id: newValue)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding {
            settingsModule.snapshot.settings[keyPath: keyPath]
        } set: { newValue in
            settingsModule.updateSetting(keyPath, newValue)
        }
    }
}
