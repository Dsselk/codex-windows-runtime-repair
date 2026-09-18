# Codex Windows Runtime Repair

Unofficial recovery tool for a Windows Codex startup issue where Codex processes are running, but the app window does not appear because the `cua_node` runtime gets stuck during staging/finalization.

> [!IMPORTANT]
> This is a recovery-only tool, not a health-check tool.
>
> If Codex already launches normally, do not run this script.

## Supported version

Currently verified for:

- OpenAI Codex for Windows `26.911.7940.0`

The script intentionally fails closed on unverified Codex versions.

## Symptoms

This workaround may help if:

- Multiple `ChatGPT.exe` / `Codex.exe` processes are visible in Task Manager
- The Codex window does not appear
- `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node` contains folders such as:

```text
.staging-<hash>-xxxxxx
```

- The corresponding finalized runtime folder is missing or incomplete

If Codex already opens normally, this tool is not needed.

## Requirements

- Windows
- OpenAI Codex for Windows `26.911.7940.0`
- Administrator privileges
- Windows PowerShell 5.1

## Usage

> [!WARNING]
> Save any work before running the script. It may stop running ChatGPT/Codex processes and request administrator privileges.

1. Download `Codex_Runtime_Repair.cmd`
2. Double-click it
3. Accept the administrator prompt using the same Windows account
4. Wait for the repair and verification process to finish
5. Start Codex normally

If the script reports that no matching staging/manual directory exists, it will exit without modifying the runtime. This is intentional fail-closed behavior.

## What it does

The script:

- Detects the installed Codex package
- Refuses unverified Codex package versions
- Validates the official packaged `cua_node` runtime before making changes
- Reproduces the verified Codex runtime content-ID algorithm for `26.911.7940.0`
- Uses the current packaged runtime to determine the expected runtime hash
- Requires matching staging/manual recovery evidence before performing a repair
- Stops only matching Codex processes owned by the current Windows user
- Uses a per-user mutex to prevent concurrent repair instances
- Preserves existing final/manual recovery data until a replacement has been verified
- Copies the runtime from the real source path to a separate work directory using `robocopy`
- Verifies the complete file set and file sizes
- Verifies SHA-256 content digests for:
  - `manifest.json`
  - `bin/node.exe`
  - `bin/node_repl.exe`
- Finalizes the repaired runtime only after verification succeeds
- Cleans matching temporary staging/manual directories only after the final runtime has been verified
- Fails closed if Codex restarts during a critical repair stage

Temporary `SUBST` mappings are still used for safe short-path validation where needed, but runtime copy writes use the real source and work-directory paths.

## Runtime identity

For the currently supported Codex version, the runtime content ID is derived from:

```text
manifest.json
bin/node.exe
bin/node_repl.exe
```

The script reproduces the runtime identity algorithm used by the verified Codex package instead of trusting the newest staging directory name.

This behavior is version-specific. Future Codex versions are rejected until their runtime identity implementation is verified.

## Safety

The script does not intentionally modify:

- Your projects
- `~/.codex`
- Codex conversation history
- Login/session data
- Files inside `C:\Program Files\WindowsApps`

Runtime file changes are restricted to:

```text
%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node
```

The script also includes safeguards for:

- Same-user administrator elevation
- Process ownership
- Concurrent repair instances
- Reparse points
- Temporary drive mapping ownership
- Failed copies and failed finalization
- Codex restarting during repair

Recovery copies are retained when a repair cannot safely complete.

An incomplete pre-existing finalized runtime may be preserved as a `<hash>.bad-*` backup after a successful replacement. The script does not automatically delete these `.bad-*` recovery backups.

## Release checksum

Current release candidate SHA-256:

```text
95CF55D56E4906E2CC4104A6FD90C78F8ECF69FF5E96E055FA670FC427544896
```

## Notes

This workaround targets a specific `cua_node` runtime staging/finalization failure.

It is not intended to diagnose every Codex startup problem.

If the failure is caused by something other than the `cua_node` runtime, this script may not help.

Because the runtime implementation can change between Codex releases, support for future versions must be verified before they are added.

## Disclaimer

This is an unofficial community workaround and is not affiliated with or endorsed by OpenAI.

Use at your own risk.
