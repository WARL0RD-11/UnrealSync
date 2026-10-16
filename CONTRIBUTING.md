# Contributing to UnrealSync

Issues and pull requests are welcome. Please include Windows/Unreal version information, sanitized logs, and reproduction steps. Never upload confidential game source, project assets, developer credentials, or source-control INI files.

Run `python3 -m unittest discover -s tests -v` to validate the Git hook interface without Unreal Engine. On Windows, also test PowerShell parsing and perform `-DryRun` on a disposable Unreal project. Real Unreal builds and Windows notification popups are not tested by the mock CI.

Keep the default cleanup conservative; dangerous operations such as deleting `Saved`, project DDC, or binary-only plugin artifacts must remain explicit opt-ins. Do not weaken Git-tracked file protection or hook-manager coexistence without discussing the tradeoffs.
