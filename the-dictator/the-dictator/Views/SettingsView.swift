import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var appModel: AppModel

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
                TextField("Model path", text: binding(\.modelPath))
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
