# Issues and Fixes

Every real bug hit while building this project, in the order encountered. Kept separate from the README so the setup instructions stay clean, and so this reads as what it is: a debugging log, not polished documentation.

Each entry: **Symptom - Cause - Fix.**

---

## Phase 1 - Manual build

### 1. Region mismatch
**Symptom:** `aws ssm describe-instance-information` returned nothing for either instance, despite IAM roles and networking looking correct.
**Cause:** Both EC2 instances had been launched in `eu-north-1` (Stockholm) by mistake, while every other resource (S3, IAM, the CLI's configured region) was in `us-east-1`.
**Fix:** Terminated both instances, relaunched in the correct region, double-checked the region dropdown before every subsequent launch by using --region <us-east-1> tag for query statements.

### 2. EC2 instance role missing the S3 read permission
**Symptom:** `Read-S3Object` on the instance failed with `AccessDenied` when pulling the audit script from S3.
**Cause:** The IAM policy only granted `s3:PutObject` on `findings/*` (for writing results) - nothing granted `s3:GetObject` on the script's location.
**Fix:** Added a dedicated `ReadScriptFromS3` statement scoped to `s3:GetObject` on the `scripts/*` prefix.

### 3. Windows: `Out-File` failed - `C:\tmp` doesn't exist
**Symptom:** `Out-File : Could not find a part of the path 'C:\tmp\...'`.
**Cause:** The script's local staging path was written as if cross-platform (`/tmp` semantics), but Windows doesn't auto-create `C:\tmp`.
**Fix:** Added `New-Item -ItemType Directory -Path C:\tmp -Force` as a preceding step (later folded into the script itself for the Terraform build).

### 4. Windows: `pwsh`/`Read-S3Object` not recognized, despite installing PS7
**Symptom:** `The term 'Read-S3Object' is not recognized...` on Windows, even after confirming PowerShell 7 was installed on the box.
**Cause:** `AWS-RunPowerShellScript` invokes **Windows PowerShell 5.1** by default on Windows targets - a completely separate binary and module path from `pwsh.exe` (PS7). The SSM command was calling the script directly (`C:\audit.ps1`), which ran it under 5.1, where `$IsWindows`/`$IsLinux` don't exist and AWS Tools wasn't installed.
**Fix:** Invoke `pwsh` explicitly in every SSM command instead of relying on the default interpreter.

### 5. `AWS.Tools.S3` not installed under PS7 on Linux
**Symptom:** `The term 'Read-S3Object' is not recognized...` on Linux, once `pwsh` was being invoked correctly.
**Cause:** The AWS Tools modules were never installed for the pwsh module path - installing `pwsh` itself doesn't bring them along.
**Fix:** Ran `Install-Module AWS.Tools.Installer` then `Install-AWSToolsModule AWS.Tools.S3,AWS.Tools.EC2` via SSM, explicitly under `pwsh`.

### 6. `RemoteAccessAllowedToInternet` always `false`, even with the port open
**Symptom:** After deliberately opening SSH to `0.0.0.0/0` for a live test, the finding still reported `false` - the CRITICAL status never appeared.
**Cause:** The AWS.Tools.EC2 SDK version installed exposes the IP range property as **`Ipv4Ranges`**, not `IpRanges`. The script checked `$perm.IpRanges`, which doesn't exist on this object - PowerShell silently returns `$null` for a missing property rather than throwing, so the loop just never ran and the function fell through to `return $false`. No error anywhere; checked security-group as initial suspect but no problem found.
**Fix:** Diagnosed by uploading a small standalone debug script that dumped `$sg.IpPermissions | ConvertTo-Json` directly from the instance - confirmed the real property name at runtime rather than guessing from documentation. Changed `$perm.IpRanges` to `$perm.Ipv4Ranges`.

---

## Phase 2 - Terraform-automated build

### 1. Windows: PS7 never installed - silent user-data failure
**Symptom:** `pwsh` not recognized on the Windows instance, and a direct `Test-Path` check for `pwsh.exe` came back empty - PS7 was missing
**Cause:** Windows Server 2022's AMI EC2Launch v2 agent doesn't reliably shows `<powershell>` user-data script errors in the instance console log (initially only PS 5.1 is available by 2022 AMI). `aws ec2 get-console-output` showed a completely clean boot, no trace the script had even run, no error of any kind.
**Fix:** Installed PS7 directly via SSM (`Invoke-WebRequest` + `msiexec`) as a fallback rather than continuing to debug user-data, then installed AWS Tools under it the same way as the manual build. Longer-term fix worth doing: add explicit logging/error transcription inside the user-data script itself (e.g. `Start-Transcript` to a known file), so future failures are at least visible in the console log.

### 2. `pwsh` still not found immediately after MSI install
**Symptom:** Right after confirming the PS7 MSI install succeeded, the very next SSM command still got `pwsh: command not found`.
**Cause:** The MSI's `ADD_PATH=1` updates the system PATH, but the SSM Agent is a long-running Windows service that had already loaded its environment before the install - it doesn't pick up PATH changes without a restart.
**Fix:** Called `pwsh.exe` by its full path (`C:\Program Files\PowerShell\7\pwsh.exe`) in subsequent commands instead of relying on PATH resolution - avoids needing a reboot mid-workflow.

---

## Cross-cutting lessons

- **A missing property/key returns `$null`/`None` silently in both PowerShell and the AWS SDKs - it doesn't throw.** Several of the bugs looked like "nothing happened" rather than an error, which made them slower to find than a stack trace would have been. Dumping the actual runtime object (`ConvertTo-Json`) helped.
- **Nested-quote shell commands are fragile across PowerShell/SSM boundaries.** Several errors (`ParserError`, `Missing statement after '='`) came from three-deep quote nesting between PowerShell > SSM JSON > the remote shell. Splitting into an array of separate, simpler commands (or uploading a standalone script file) was consistently more reliable than one-line code.