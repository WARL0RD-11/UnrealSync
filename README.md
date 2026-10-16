# UnrealSync

**Automatic Unreal Engine project cleanup, project-file regeneration, and Editor builds after relevant Git merges/pulls.**

UnrealSync is a small, open-source, **Windows-first** developer utility for Unreal Engine projects using Git and GitHub (including GitHub Desktop). It uses local Git hooks plus Windows PowerShell. It is **not** a GitHub Action, an Unreal plugin, or a cloud build service.

## Why?

Changes to Unreal C++ and build targets can leave local compiled artifacts out of sync with the code developers just pulled. A clean regeneration/rebuild can fix **stale binary or reflection metadata issues**, although it does **not** repair genuinely renamed/removed UFUNCTIONs, UPROPERTYs, broken Blueprint references, or actual compiler errors.

## Features

- Local `post-merge` / `post-rewrite` hooks for supported merge and rebase workflows (including fast-forward merges).
- Configurable watched Git paths: ignore Blueprint/asset-only pulls, or add other important build inputs.
- Auto-detects a single `.uproject` in repo root; explicit path for monorepos/nested projects.
- Discovers Editor target via `Source/*Editor.Target.cs`, supports override and Blueprint-only generation.
- Supports Launcher Unreal installations, registered GUID installations, and Unreal source trees; `UE_ENGINE_ROOT`/`-EngineRoot` override.
- `Standard` or opt-in `Deep` clean, `-DryRun`, tracked-file and junction protection.
- Preserves available `Saved/Config/**/SourceControlSettings.ini` across `Deep` cleanup.
- Windows notification area messages for started, succeeded, failed, skipped, and deferred builds (best effort).
- Machine-local logs/status under Git metadata (`.git/unrealsync/`, including worktree-compatible `git --git-path`).
- GitHub Desktop compatible **when that Git client executes the configured hooks**.

## Supported environments

- Windows 10/11; Git for Windows; Windows PowerShell 5.1; compatible Unreal Engine 5 build tools and Visual Studio C++ toolchain.
- Linux/macOS build automation **not yet supported**. Contributions welcome.
- A single configured Unreal project per installed repository. Multiple projects in one repo are possible only by selecting one `ProjectFile` at a time in this version.

## Quick start

**1.** Download and extract this repository (or clone it somewhere outside your game repository).

**2.** Open PowerShell in the extracted UnrealSync folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-UnrealSync.ps1 -RepositoryPath 'D:\Games\MyGame'
```

For a nested project or an engine monorepo:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-UnrealSync.ps1 `
  -RepositoryPath 'D:\Games\MyMonorepo' `
  -ProjectFile 'Games/MyGame/MyGame.uproject'
```

The installer copies `.unrealsync/` and `.githooks/` into the target repository and creates `.unrealsync.json`. It sets **local** `core.hooksPath=.githooks` in that clone. It refuses to overwrite unrelated hook managers or preexisting custom hooks.

**3.** Preview cleanup **without deleting anything**:

```powershell
cd 'D:\Games\MyGame'
powershell -NoProfile -ExecutionPolicy Bypass -File .\.unrealsync\UnrealSync.ps1 -Mode Full -DryRun
```

**4.** Close Unreal Editor and run an optional manual smoke test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\.unrealsync\UnrealSync.ps1 -Mode Full
```

**5.** Commit `.unrealsync/`, `.githooks/`, and `.unrealsync.json` to your game's Git repository; share [TEAM_SETUP.md](TEAM_SETUP.md) with developers. Every clone requires the one-time `git config --local core.hooksPath .githooks` (or the instructions in TEAM_SETUP.md); pulling hook files alone does not install them.

## Cleanup modes

| Configuration / flag | Action |
|---|---|
| `CleanupProfile: Standard` (default) | Removes local project `Binaries/`, `Intermediate/`, `.vs/`, and root `*.sln`. |
| `CleanupProfile: Deep` | Also removes project `Saved/`, project `DerivedDataCache/`, and **untracked** root `*.vsconfig` files. Saves and restores source-control INI when present. |
| `-Mode Auto` | Compares two Git revisions; skips cleanup/build unless watched files changed. |
| `-Mode Full` | Ignores watched-file filter and always performs **the configured cleanup profile** and rebuild. |
| `-DryRun` | Validates and lists planned deletions; does not delete or build. |
| `-CleanPluginArtifacts` | Also cleans plugin `Binaries` and `Intermediate`, after tracked-file checks. Dangerous for binary-only plugins. |

**Warning:** `Deep` cleanup destroys local autosaves, screenshots, crash reports, local logs, and potentially other untracked data in `Saved/`. It also forces asset/shader caches to regenerate. Back up anything you need. `.vsconfig` may describe required Visual Studio components; tracked copies are preserved.

## Configuration (`.unrealsync.json`)

Example for a project at the repository root:

```json
{
  "ProjectFile": "MyGame.uproject",
  "EditorTarget": "",
  "CleanupProfile": "Standard",
  "Platform": "Win64",
  "BuildConfiguration": "Development",
  "Notifications": true,
  "CleanPluginArtifacts": false,
  "WatchPatterns": [
    "Source/*",
    "Plugins/*.uplugin",
    "Plugins/*.cs",
    "Config/DefaultEngine.ini",
    "*.uproject",
    ".unrealsync/*",
    ".unrealsync.json"
  ]
}
```

`WatchPatterns` use **PowerShell `-like` wildcards**, matched against repository-relative Git paths with `/`. `Source/*` matches files under any Source subdirectory. Change the patterns for your repository. When installed in a nested project, the installer prefixes paths automatically. Specify `EditorTarget` when multiple editor targets exist. Avoid committing an absolute engine path: instead set `UE_ENGINE_ROOT` per developer machine or pass `-EngineRoot` manually.

For automatic deep cleanup when watched files change, set `"CleanupProfile": "Deep"`. The default watched paths cover `Source`, `.uproject`, `Config/DefaultEngine.ini`, and UnrealSync itself.

## Day-to-day Git workflow

```bash
git pull origin main
# or, while on a feature branch:
git fetch origin
git merge origin/main
```

When relevant changed files arrive and the hook executes, UnrealSync blocks the Git operation until it finishes the cleanup/build, then leaves the hook with exit code 0 regardless of the build outcome. **Do not treat a successful pull as a successful Unreal build.** Check the notification and status/log. Hooks do not fire for `fetch`, `push`, no-op merges, or PR merges performed on GitHub's website. Rebase detection is best effort; certain rebase/fast-forward paths may bypass the `post-rewrite` hook.

## Inspect the result

```powershell
# Current Git metadata path depends on normal clones versus worktrees.
$state = git rev-parse --git-path unrealsync
Get-Content (Join-Path $state 'status.json') -Raw | ConvertFrom-Json | Format-List
Get-Content (Join-Path $state 'latest.log') -Tail 30
```

`State` values include `Checking`, `Running`, `Skipped`, `Succeeded`, `Failed`, `Deferred`, and `DryRun`. A stale status timestamp is not evidence that the most recent pull was rebuilt. Windows may suppress desktop notifications.

## Safety and limitations

- Git-tracked files are never intentionally deleted. If a tracked file is inside a requested cleanup directory, the tool **stops** rather than modifying your working tree.
- The tool refuses to clean directory junctions/symlinks and checks nested reparse points.
- The Unreal Editor should be closed; if open, the build is deferred and must be retried manually.
- Deleting `Saved/` may affect editor-local preferences other than source-control INI; only that specific INI filename is preserved.
- Git operations complete independently of the build outcome; see `status.json` and `latest.log`.
- For projects with specialized engine builds, Wwise, marketplace/precompiled plugins, or unusual build targets, perform a dry run and smoke test before enabling team-wide automation.
- Git hook configuration is per local clone; existing hook managers must be integrated manually.
- CI tests mock PowerShell invocation and validate PowerShell syntax; **they do not compile real Unreal projects**.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Unreal Engine and GitHub are trademarks of their respective owners; this project is not affiliated with Epic Games or GitHub.

## License

UnrealSync is **free-to-use, source-available software** licensed under the **UnrealSync Source-Available License v1.0**.

You are welcome to use and customize UnrealSync for personal, educational, internal team, and commercial Unreal Engine projects.

**Redistribution, republishing, sublicensing, resale, or commercial distribution of UnrealSync itself, including modified versions, is prohibited**, except for permitted private sharing within your development team.

Games and other independent projects built using UnrealSync may be sold or distributed commercially without royalties.

See the [LICENSE](LICENSE) file for the full terms.

Copyright © 2026 UnrealSync contributors. All rights reserved except as expressly licensed.
