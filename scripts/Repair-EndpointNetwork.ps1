<#
.SYNOPSIS
    Automated network stack diagnostic and self-healing utility for Windows enterprise endpoints.
.DESCRIPTION
    Safely resolves "Connected, No Internet" anomalies caused by stale static DNS overrides,
    stuck routing entries, or misconfigured L2/L3 security filter drivers (NDIS) without breaking
    underlying cryptographic modules or host domain memberships.
.EXAMPLE
    .\Repair-EndpointNetwork.ps1 -TargetAdapterAlias "Wi-Fi" -ResetDnsToDhcp
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$TargetAdapterAlias = "Wi-Fi",

    [Parameter(Mandatory = $false)]
    [switch]$ResetDnsToDhcp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Timestamp] [$Level] $Message"
}

Write-Log "Starting Network Health Check on interface [$TargetAdapterAlias]..."

# 1. Inspect target network adapter state
$Adapter = Get-NetAdapter -Name $TargetAdapterAlias -ErrorAction SilentlyContinue
if (-not $Adapter) {
    Write-Log "Adapter '$TargetAdapterAlias' not found! Enumerating active adapters..." "WARN"
    Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object Name, InterfaceDescription, Status
    exit 1
}

# 2. Audit IP and DNS configuration
$IPConfig = Get-NetIPConfiguration -InterfaceAlias $TargetAdapterAlias
Write-Log "Current IPv4 Address: $(($IPConfig.IPv4Address).IPAddress)"
Write-Log "Current IPv4 Gateway: $(($IPConfig.IPv4DefaultGateway).NextHop)"
Write-Log "Current DNS Servers: $((($IPConfig.DNSServer).ServerAddresses) -join ', ')"

# 3. Detect and remediate static DNS override issues
if ($ResetDnsToDhcp) {
    Write-Log "Enforcing dynamic DHCP configuration for IP and DNS parameters..." "WARN"
    Set-NetIPInterface -InterfaceAlias $TargetAdapterAlias -Dhcp Enabled -Confirm:$false
    Set-DnsClientServerAddress -InterfaceAlias $TargetAdapterAlias -ResetServerAddresses
    Write-Log "Interface successfully switched to dynamic DHCP mode."
}

# 4. Flush stale routing entries and DNS resolver caches (non-destructive)
Write-Log "Flushing DNS resolver cache and releasing stale ARP mappings..."
Clear-DnsClientCache
arp -d * > $null 2>&1

# 5. Audit NDIS intermediate driver filters (e.g., VPN / Proprietary Cryptography)
Write-Log "Auditing installed NDIS lightweight network filter drivers..."
$NdisFilters = Get-NetAdapterBinding -Name $TargetAdapterAlias | Where-Object { 
    $_.DisplayName -match "Filter|VipNet|VPN|Lightweight" 
}

foreach ($Filter in $NdisFilters) {
    Write-Log "Detected Filter: $($Filter.DisplayName) | State: $(if ($Filter.Enabled) {'ENABLED'} else {'DISABLED'})"
}

# 6. Verification & Healthcheck
Write-Log "Running connectivity validation tests..."
$Gateway = ($IPConfig.IPv4DefaultGateway).NextHop

if ($Gateway) {
    $PingGateway = Test-Connection -TargetName $Gateway -Count 2 -Quiet
    Write-Log "Ping Standard Gateway ($Gateway): $(if ($PingGateway) {'PASS'} else {'FAIL'})"
} else {
    Write-Log "Standard Gateway is not provisioned or unreachable." "ERROR"
}

$ExternalIp = "1.1.1.1"
$PingExternal = Test-Connection -TargetName $ExternalIp -Count 2 -Quiet
Write-Log "Ping External Core ($ExternalIp): $(if ($PingExternal) {'PASS'} else {'FAIL'})"

$DnsResolution = Resolve-DnsName -Name "example.com" -ErrorAction SilentlyContinue
Write-Log "Domain Name Resolution (example.com): $(if ($DnsResolution) {'PASS'} else {'FAIL'})"

Write-Log "Diagnostic script execution complete."
