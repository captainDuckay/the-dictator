# New Agent Setup — Milestone 1 Skills

This project should use the following installed skills for Milestone 1 work.

## Installed skills

1. `avdlee/swiftui-agent-skill@swiftui-expert-skill`
   - Local path: `~/.agents/skills/swiftui-expert-skill`
   - Purpose: SwiftUI architecture/patterns for app shell, MenuBarExtra, settings UI scaffolding.

2. `dimillian/skills@macos-menubar-tuist-app`
   - Local path: `~/.agents/skills/macos-menubar-tuist-app`
   - Purpose: macOS menubar app guidance, menu-focused app behavior, shell workflow.

3. `sickn33/antigravity-awesome-skills@software-architecture`
   - Local path: `~/.agents/skills/software-architecture`
   - Purpose: architecture discipline for service boundaries and state ownership.

4. `willsigmon/sigstack@Preferences Store Expert`
   - Local path: `~/.agents/skills/preferences-store-expert`
   - Purpose: settings persistence patterns and migration-safe preferences design.

5. `vabole/apple-skills@usernotifications`
   - Local path: `~/.agents/skills/usernotifications`
   - Purpose: UserNotifications API reference for notification wrapper/service.

6. `aj-geddes/useful-ai-prompts@application-logging`
   - Local path: `~/.agents/skills/application-logging`
   - Purpose: logging strategy/reference (adapted to Swift `os.Logger` patterns).

## How agents should apply these in Milestone 1

- **App shell + menu bar + settings scaffold**: use `swiftui-expert-skill` + `macos-menubar-tuist-app`.
- **State machine scaffolding and module boundaries**: use `software-architecture`.
- **Settings store scaffolding**: use `Preferences Store Expert` concepts for typed, centralized preferences.
- **Notification utility wrapper**: use `usernotifications` docs.
- **Dev logging scaffolding**: use `application-logging` as structure inspiration, but implement natively in Swift.

## Install commands (for a fresh machine)

```bash
npx skills add avdlee/swiftui-agent-skill@swiftui-expert-skill -g -y
npx skills add dimillian/skills@macos-menubar-tuist-app -g -y
npx skills add sickn33/antigravity-awesome-skills@software-architecture -g -y
npx skills add "willsigmon/sigstack@Preferences Store Expert" -g -y
npx skills add vabole/apple-skills@usernotifications -g -y
npx skills add aj-geddes/useful-ai-prompts@application-logging -g -y
```

## Notes

- These are global installs and are symlinked for Pi/Junie-compatible agents.
- Prefer native Swift/macOS patterns when a skill’s examples are in another language/runtime.
