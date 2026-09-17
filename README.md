# Codex Windows Runtime Repair

Unofficial workaround for a Windows Codex startup issue where Codex processes are running, but the app window does not appear because the `cua_node` runtime gets stuck during staging.

## Symptoms

This workaround may help if:

- Multiple `ChatGPT.exe` processes are visible in Task Manager
- The Codex window does not appear
- `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node` contains folders like:

```text
.staging-<hash>-xxxxxx
```

- The corresponding finalized runtime folder is missing

## Requirements

- Windows
- Codex for Windows installed
- Administrator privileges

## Usage

> [!WARNING]
> Save any work before running the script. It will stop running ChatGPT/Codex processes and request administrator privileges.

1. Download `Codex_Runtime_Repair.cmd`
2. Double-click it
3. Accept the administrator prompt
4. Wait for the copy and verification process to finish
5. Start Codex normally

## What it does

The script:

- Detects the current Codex installation
- Detects the affected `cua_node` runtime hash
- Stops running ChatGPT/Codex processes before repairing the runtime
- Uses temporary `SUBST` drive mappings to shorten long Windows paths
- Copies the runtime using `xcopy /G`
- Verifies the copied file set and file sizes before finalizing the runtime
- Finalizes the repaired runtime only after verification succeeds
- Cleans failed staging folders only after verification succeeds

The short-path mapping is important because some Codex runtime paths can exceed traditional Windows path limits.

The verification compares relative file paths and file sizes. It is not a cryptographic checksum.

## Safety

The script does not intentionally modify:

- Your projects
- `~/.codex`
- Codex conversation history
- Login/session data
- Files inside `C:\Program Files\WindowsApps`

The script only modifies Codex runtime data under:

```text
%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node
```

## Notes

This workaround was created after repeatedly encountering the same Codex Windows runtime staging failure across multiple Codex updates.

It has worked repeatedly on the original test system, but it may not apply to every Codex startup problem.

If the failure is caused by something other than `cua_node` runtime staging, this script may not help.

## Disclaimer

This is an unofficial community workaround and is not affiliated with or endorsed by OpenAI.

Use at your own risk.
