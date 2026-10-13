<#
.SYNOPSIS
    Reports the last sign-in of every guest account in the tenant.

.DESCRIPTION
    Reads all users with userType 'Guest' from Microsoft Graph, including signInActivity,
    and writes a CSV sorted by how long ago each guest last signed in.

    signInActivity needs an Entra ID P1/P2 licence in the tenant and the
    AuditLog.Read.All permission. Graph has kept sign-in activity since April 2020; a guest
    with no value has not signed in since then (or never redeemed the invitation).

    With -IncludeExchange the script also connects to Exchange Online and adds whether the
    guest is hidden from the address lists (GuestMailUser recipients).

.EXAMPLE
    ./Get-HcrGuestLastSignIn.ps1

.EXAMPLE
    ./Get-HcrGuestLastSignIn.ps1 -StaleDays 180 -IncludeExchange -OutFile .\guests.csv
#>
[CmdletBinding()]
param(
    # Guests whose last sign-in is older than this (or who never signed in) are flagged stale.
    [int]$StaleDays = 90,

    [string]$OutFile = (Join-Path $PWD ("HcrGuestLastSignIn_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date))),

    [switch]$IncludeExchange
)

$ErrorActionPreference = 'Stop'

Import-Module Microsoft.Graph.Users -ErrorAction Stop

Connect-MgGraph -Scopes 'User.Read.All', 'AuditLog.Read.All' -NoWelcome

$properties = @(
    'Id', 'DisplayName', 'Mail', 'UserPrincipalName', 'AccountEnabled', 'CreatedDateTime',
    'ExternalUserState', 'ExternalUserStateChangeDateTime', 'SignInActivity'
)

Write-Host 'Retrieving guest accounts from Microsoft Graph...'
$guests = Get-MgUser -All -Filter "userType eq 'Guest'" -Property $properties |
    Select-Object $properties

Write-Host ("Found {0} guest accounts." -f @($guests).Count)

$hiddenByUpn = @{}
if ($IncludeExchange) {
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-ExchangeOnline -ShowBanner:$false
    Get-MailUser -RecipientTypeDetails GuestMailUser -ResultSize Unlimited |
        ForEach-Object { $hiddenByUpn[$_.UserPrincipalName.ToLowerInvariant()] = $_.HiddenFromAddressListsEnabled }
}

$now = Get-Date

function Get-Latest([object[]]$Dates) {
    $Dates | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
}

$report = foreach ($g in $guests) {
    $activity = $g.SignInActivity
    $interactive = $activity.LastSignInDateTime
    $nonInteractive = $activity.LastNonInteractiveSignInDateTime
    $lastSuccessful = $activity.LastSuccessfulSignInDateTime
    $lastAny = Get-Latest @($interactive, $nonInteractive, $lastSuccessful)

    $daysSince = if ($lastAny) { [int][math]::Floor(($now - $lastAny.ToLocalTime()).TotalDays) } else { $null }

    $row = [ordered]@{
        DisplayName                 = $g.DisplayName
        Mail                        = $g.Mail
        UserPrincipalName           = $g.UserPrincipalName
        AccountEnabled              = $g.AccountEnabled
        InvitationState             = $g.ExternalUserState
        InvitationStateChanged      = $g.ExternalUserStateChangeDateTime
        Created                     = $g.CreatedDateTime
        LastInteractiveSignIn       = $interactive
        LastNonInteractiveSignIn    = $nonInteractive
        LastSuccessfulSignIn        = $lastSuccessful
        LastSignInAny               = $lastAny
        DaysSinceLastSignIn         = $daysSince
        Stale                       = (-not $lastAny) -or ($daysSince -gt $StaleDays)
    }
    if ($IncludeExchange) {
        $key = "$($g.UserPrincipalName)".ToLowerInvariant()
        $row.HiddenFromAddressLists = if ($hiddenByUpn.ContainsKey($key)) { $hiddenByUpn[$key] } else { $null }
    }
    $row.Id = $g.Id
    [pscustomobject]$row
}

# Never-signed-in first, then longest ago.
$report = $report | Sort-Object @{ Expression = { $null -ne $_.LastSignInAny } }, LastSignInAny

$report | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8

$total         = @($report).Count
$never         = @($report | Where-Object { -not $_.LastSignInAny }).Count
$pending       = @($report | Where-Object { $_.InvitationState -eq 'PendingAcceptance' }).Count
$stale         = @($report | Where-Object Stale).Count
$noActivityAll = @($report | Where-Object { $null -eq $_.LastInteractiveSignIn -and $null -eq $_.LastNonInteractiveSignIn -and $null -eq $_.LastSuccessfulSignIn }).Count

if ($total -gt 0 -and $noActivityAll -eq $total) {
    Write-Warning 'No guest has any sign-in data. signInActivity needs an Entra ID P1/P2 licence and AuditLog.Read.All consent.'
}

Write-Host ''
Write-Host "Guests total:                    $total"
Write-Host "Invitation not accepted:         $pending"
Write-Host "No sign-in recorded:             $never"
Write-Host "Stale (> $StaleDays days or never): $stale"
Write-Host ''

$report | Select-Object -First 25 DisplayName, Mail, InvitationState, LastSignInAny, DaysSinceLastSignIn |
    Format-Table -AutoSize | Out-Host

Write-Host "Full report written to $OutFile"

Disconnect-MgGraph | Out-Null
if ($IncludeExchange) { Disconnect-ExchangeOnline -Confirm:$false }
