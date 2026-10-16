# UnrealSync — Team member installation

These steps apply **after the maintainer has installed UnrealSync into your game repository and committed `.unrealsync/`, `.githooks/`, and `.unrealsync.json`.** You do not need the separate UnrealSync distribution archive.

## One-time, per clone

1. Save work and close Unreal Editor. Pull the version of the project that includes UnrealSync using your normal Git or GitHub Desktop workflow.
2. Open PowerShell at the root of your **game repository**.
3. If your repository does **not** use another Git hook manager, run:

   ```powershell
   git config --local core.hooksPath .githooks
   git config --local --get core.hooksPath
   ```

   Expected: `.githooks`. If your team already uses Husky, pre-commit, or customized Git hooks, contact the maintainer to integrate instead of overwriting the configuration.
4. If Unreal is not in the standard Epic Games install directory, set the machine-local path, e.g.:

   ```powershell
   [Environment]::SetEnvironmentVariable('UE_ENGINE_ROOT', 'D:\Unreal\UE_5.5', 'User')
   ```

   Restart GitHub Desktop and your terminal if you changed environment variables.
5. Close Unreal Editor, then run a dry run:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\.unrealsync\UnrealSync.ps1 -Mode Full -DryRun
   ```

6. If this is your first installation and the initial pull included C++ changes **before** you installed hooks, you may need a one-time manual build:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\.unrealsync\UnrealSync.ps1 -Mode Full
   ```

## Daily use

- Use `Pull origin` or merge `main` into your feature branch in GitHub Desktop, or `git pull` / `git merge` in a terminal.
- Watched file changes trigger cleanup and a local Unreal build automatically. Blueprint-only/asset-only pulls skip rebuilding, according to `.unrealsync.json`.
- **Keep Unreal Editor closed** while UnrealSync is running. Open your project only after the log/status reports `Succeeded` or `Skipped` for the latest operation.
- Windows notification popups are optional and not guaranteed to appear. Use Git status and UnrealSync status/log to verify completion.

## Troubleshooting

```powershell
$state = git rev-parse --git-path unrealsync
Get-Content (Join-Path $state 'status.json') -Raw | ConvertFrom-Json | Format-List
Get-Content (Join-Path $state 'latest.log') -Tail 50
```

If `Deferred` because Unreal Editor was running, close it, then manually run `-Mode Full`. If `Failed`, investigate the build log and retry after fixing the issue. If a hook is not invoked, verify `git config --local --get core.hooksPath` and the executable `.githooks/post-merge`/`post-rewrite` files.

**Note:** The hook returns success so that Git's successful merge is not mistaken for a failed merge, even when the Unreal compilation fails. Always check the UnrealSync status independently.
