import Foundation

@MainActor
protocol DictationSettingsProviding: AnyObject {
    var currentSettings: AppSettings { get }
}

@MainActor
protocol ModelManagerSettingsProviding: DictationSettingsProviding {
    func update(_ mutate: (inout AppSettings) -> Void)
}
