import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var appModel: AppModel

    var body: some View {
        Form {
            Section("Hotkeys") {
                TextField("Push-to-talk hotkey", text: binding(\.pushToTalkHotkey))
                TextField("Paste last transcript hotkey", text: binding(\.pasteLastTranscriptHotkey))
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
