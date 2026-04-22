import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var appModel: AppModel
    @State private var isShowingCustomModelImporter = false

    var body: some View {
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

                if let hint = appModel.modelManagerOnboardingHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appModel.isUsingFallbackCatalog {
                    Label("Using fallback model catalog", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(appModel.modelCatalogRefreshDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(appModel.availableModels) { descriptor in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(appModel.modelLabel(for: descriptor))
                                .fontWeight(settingsStore.settings.selectedModelID == descriptor.id && !settingsStore.settings.useCustomModelPath ? .semibold : .regular)
                            Spacer()
                            Text(appModel.modelStatus(for: descriptor.id))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(appModel.modelResourceHint(for: descriptor))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(appModel.modelVersionHint(for: descriptor))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Use") {
                                appModel.selectModel(id: descriptor.id)
                            }
                            .disabled(!appModel.isModelInstalled(descriptor.id))

                            if appModel.isModelInstalled(descriptor.id) {
                                if appModel.isModelUpdateAvailable(descriptor.id) {
                                    Button("Update") {
                                        appModel.downloadModel(id: descriptor.id)
                                    }
                                    .disabled(descriptor.downloadURL == nil)
                                }

                                if appModel.canDeleteModel(descriptor.id) {
                                    Button("Delete") {
                                        appModel.deleteModel(id: descriptor.id)
                                    }
                                }
                            } else if case .downloading = appModel.modelDownloadStates[descriptor.id] {
                                Button("Cancel") {
                                    appModel.cancelModelDownload(id: descriptor.id)
                                }
                            } else {
                                Button("Download") {
                                    appModel.downloadModel(id: descriptor.id)
                                }
                                .disabled(descriptor.downloadURL == nil)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let modelManagerStatusMessage = appModel.modelManagerStatusMessage {
                    Text(modelManagerStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Model Catalog") {
                    appModel.refreshModelCatalog(force: true)
                }

                Toggle("Use custom local model (Advanced)", isOn: binding(\.useCustomModelPath))
                if settingsStore.settings.useCustomModelPath {
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

                        settingsStore.update { settings in
                            settings.customModelPath = url.path
                            settings.useCustomModelPath = true
                        }
                    }
                }

                Toggle("Auto-detect language", isOn: binding(\.languageAutoDetect))
                TextField("Preferred language", text: binding(\.preferredLanguage))
                Toggle("Polished output", isOn: binding(\.polishedOutputEnabled))

                LabeledContent("Capabilities") {
                    Text(appModel.backendCapabilitiesDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Audio") {
                Toggle("Audio cues", isOn: binding(\.audioCuesEnabled))

                Picker("Input microphone", selection: audioInputSelectionBinding) {
                    ForEach(appModel.audioInputOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }

                Text(appModel.audioInputStatusDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Refresh Audio Inputs") {
                    appModel.refreshAudioInputDevices()
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    Text(appModel.microphonePermissionStatus)
                }

                LabeledContent("Accessibility") {
                    Text(appModel.accessibilityPermissionStatus)
                }

                Button("Refresh Permission Status") {
                    appModel.refreshPermissionStatuses()
                }

                Button("Open Microphone Privacy Settings") {
                    appModel.openMicrophonePrivacySettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480)
    }

    private var audioInputSelectionBinding: Binding<String> {
        Binding {
            appModel.selectedAudioInputOptionID
        } set: { newValue in
            appModel.selectAudioInputOption(id: newValue)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding {
            settingsStore.settings[keyPath: keyPath]
        } set: { newValue in
            settingsStore.update { settings in
                settings[keyPath: keyPath] = newValue
            }
        }
    }
}
