param(
    [string]$S3BucketName = "csa-reports-yourname",
    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"

# Instance metadata via IMDSv2 - identical call on both OS families
$token = Invoke-RestMethod -Method PUT -Uri "http://169.254.169.254/latest/api/token" `
    -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"}
$InstanceId = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/instance-id" `
    -Headers @{"X-aws-ec2-metadata-token" = $token}

$OSFamily = if ($IsWindows) { "Windows" } elseif ($IsLinux) { "Linux" } else { "Unknown" }
$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$data = [ordered]@{
    InstanceId = $InstanceId
    OS         = $OSFamily
    Timestamp  = $Timestamp
    Security   = [ordered]@{}
    Cost       = [ordered]@{}
}

function Test-SGPortAllowedToInternet {
    param([int]$Port, [string]$InstanceId, [string]$Region)
    try {
        $sgIds = (Get-EC2Instance -InstanceId $InstanceId -Region $Region).Instances.SecurityGroups.GroupId
        foreach ($sgId in $sgIds) {
            $sg = Get-EC2SecurityGroup -GroupId $sgId -Region $Region
            foreach ($perm in $sg.IpPermissions) {
                if ($perm.FromPort -le $Port -and $perm.ToPort -ge $Port) {
                    foreach ($range in $perm.Ipv4Ranges) {
                        if ($range.CidrIp -eq "0.0.0.0/0") { return $true }
                    }
                }
            }
        }
        return $false
    } catch {
        return "CheckFailed: $($_.Exception.Message)"
    }
}

function Get-PatchStatusFromDate {
    # Shared by both OS branches: given the last-patch date (or $null if
    # unknown), returns the standard {DaysSincePatch, PatchStatus} pair.
    # Only *finding* the date differs by OS (Get-HotFix vs. log file
    # timestamps) - the staleness rule itself is identical either way.
    param([Nullable[datetime]]$LastPatchDate)

    $days = if ($LastPatchDate) { (New-TimeSpan -Start $LastPatchDate -End (Get-Date)).Days } else { -1 }
    $status = if ($days -gt 30 -or $days -eq -1) { "STALE" } else { "OK" }
    return @{ DaysSincePatch = $days; PatchStatus = $status }
}

#OS Checks - along with patch check, previledge account check and endpoint check

if ($IsWindows) {
    $data.Security.RemoteAccessPort = 3389
    $data.Security.RemoteAccessAllowedToInternet = Test-SGPortAllowedToInternet -Port 3389 -InstanceId $InstanceId -Region $Region

    try {
        $hotfixes = Get-HotFix | Sort-Object InstalledOn -Descending
        $lastPatchDate = if ($hotfixes) { $hotfixes[0].InstalledOn } else { $null }
        $patchResult = Get-PatchStatusFromDate -LastPatchDate $lastPatchDate
        $data.Security.DaysSincePatch = $patchResult.DaysSincePatch
        $data.Security.PatchStatus = $patchResult.PatchStatus
    } catch { $data.Security.PatchStatus = "CheckFailed" }

    try {
        $admins = Get-LocalGroupMember -Group "Administrators" | Select-Object -ExpandProperty Name
        $data.Security.PrivilegedAccountCount = $admins.Count
        $data.Security.PrivilegedAccounts = $admins -join ", "
        $data.Security.PrivilegedAccountSprawlFlag = $admins.Count -gt 3
    } catch { $data.Security.PrivilegedAccountCount = "CheckFailed" }

    try {
        $defender = Get-MpComputerStatus
        $data.Security.EndpointProtectionActive = $defender.RealTimeProtectionEnabled
        $data.Security.EndpointProtectionDetail = "Windows Defender, signature age: $($defender.AntivirusSignatureAge) day(s)"
    } catch { $data.Security.EndpointProtectionActive = "CheckFailed" }
}
elseif ($IsLinux) {
    $data.Security.RemoteAccessPort = 22
    $data.Security.RemoteAccessAllowedToInternet = Test-SGPortAllowedToInternet -Port 22 -InstanceId $InstanceId -Region $Region

    $osRelease = if (Test-Path /etc/os-release) { Get-Content /etc/os-release -Raw } else { "" }
    $distroFamily = if ($osRelease -match '(?i)debian|ubuntu') { "debian" }
                    elseif ($osRelease -match '(?i)rhel|amzn|centos|fedora') { "rhel" }
                    else { "unknown" }

    try {
        $lastPatchDate = $null
        if ($distroFamily -eq "debian" -and (Test-Path /var/log/apt/history.log)) {
            $lastPatchDate = (Get-Item /var/log/apt/history.log).LastWriteTime
        } elseif ($distroFamily -eq "rhel") {
            foreach ($log in @("/var/log/dnf.log", "/var/log/yum.log")) {
                if (Test-Path $log) { $lastPatchDate = (Get-Item $log).LastWriteTime; break }
            }
        }
        $patchResult = Get-PatchStatusFromDate -LastPatchDate $lastPatchDate
        $data.Security.DaysSincePatch = $patchResult.DaysSincePatch
        $data.Security.PatchStatus = $patchResult.PatchStatus
    } catch { $data.Security.PatchStatus = "CheckFailed" }

    try {
        $sudoers = @()
        foreach ($grp in @("sudo", "wheel")) {
            $line = & getent group $grp 2>$null
            if ($line) {
                $members = ($line -split ':')[3]
                if ($members) { $sudoers += $members -split ',' }
            }
        }
        $sudoers = $sudoers | Where-Object { $_ } | Select-Object -Unique
        $data.Security.PrivilegedAccountCount = $sudoers.Count
        $data.Security.PrivilegedAccounts = $sudoers -join ", "
        $data.Security.PrivilegedAccountSprawlFlag = $sudoers.Count -gt 3
    } catch { $data.Security.PrivilegedAccountCount = "CheckFailed" }

    try {
        $fwActive = $false
        $fwDetail = "none detected"
        foreach ($svc in @("ufw", "firewalld")) {
            $status = & systemctl is-active $svc 2>$null
            if ($status -eq "active") { $fwActive = $true; $fwDetail = $svc }
        }
        $data.Security.EndpointProtectionActive = $fwActive
        $data.Security.EndpointProtectionDetail = "Host firewall: $fwDetail"
    } catch { $data.Security.EndpointProtectionActive = "CheckFailed" }
}
else {
    $data.Security.CheckError = 'Unsupported OS - Windows and Linux are covered.'
}

# COST CHECKS by using AWS API only

try {
    $unattachedVolumes = Get-EC2Volume -Region $Region -Filter @{Name = "status"; Values = "available"}
    $data.Cost.UnattachedVolumeCount = $unattachedVolumes.Count
    $data.Cost.UnattachedVolumeIds = ($unattachedVolumes.VolumeId) -join ", "
    $data.Cost.UnattachedVolumeGB = ($unattachedVolumes.Size | Measure-Object -Sum).Sum

    $allAddresses = Get-EC2Address -Region $Region
    $idleEIPs = $allAddresses | Where-Object { -not $_.InstanceId }
    $data.Cost.IdleElasticIPCount = $idleEIPs.Count
    $data.Cost.IdleElasticIPs = ($idleEIPs.PublicIp) -join ", "

    $stoppedInstances = (Get-EC2Instance -Region $Region -Filter @{Name = "instance-state-name"; Values = "stopped"}).Instances
    $staleStoppedCount = 0
    foreach ($inst in $stoppedInstances) {
        if ($inst.StateTransitionReason -match '\((.*?)\)') {
            $stateDate = [datetime]::Parse($matches[1])
            if ((New-TimeSpan -Start $stateDate -End (Get-Date)).Days -gt 7) { $staleStoppedCount++ }
        }
    }
    $data.Cost.StaleStoppedInstanceCount = $staleStoppedCount
} catch {
    $data.Cost.CheckError = $_.Exception.Message
}

# OUTPUT

$jsonOutput = $data | ConvertTo-Json -Depth 5
$tempDir = if ($IsWindows) { "C:\tmp" } else { "/tmp" }
if ($IsWindows -and -not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
$fileName = "csa-$InstanceId-$(Get-Date -Format 'yyyyMMddHHmmss').json"
$localPath = Join-Path $tempDir $fileName
$jsonOutput | Out-File -FilePath $localPath -Encoding utf8

Write-S3Object -BucketName $S3BucketName -File $localPath `
    -Key "data/$InstanceId/$fileName" -Region $Region

Write-Output "CSA audit complete for $InstanceId ($OSFamily)."
Write-Output "Data uploaded to s3://$S3BucketName/data/$InstanceId/$fileName"
Write-Output $jsonOutput
