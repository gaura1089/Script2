Import-Module ActiveDirectory

# =========================================
# PATHS
# =========================================
$BaseFolder = "C:\Users\Gaurav.26\OneDrive - Coforge Limited\Documents\UserAutomation"
$OUConfigPath = "$BaseFolder\OU_Config\OUs.json"
$LogFolder = "$BaseFolder\Logs"
$csvPath = "$BaseFolder\bulk_users.csv"

if (!(Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

$Users = Import-Csv $csvPath
$OUMap = Get-Content $OUConfigPath -Raw | ConvertFrom-Json

# ✅ TIMESTAMP (ONE FILE PER RUN 🔥)
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$SuccessFile = "$LogFolder\bulk_success_$timestamp.csv"
$ErrorFile   = "$LogFolder\bulk_error_$timestamp.csv"

# =========================================
# EXCHANGE CONNECT
# =========================================
$Cred = Import-Clixml "$BaseFolder\Creds\Cred.xml"

$Session = New-PSSession -ConfigurationName Microsoft.Exchange `
    -ConnectionUri http://IN-TZ1-EXMBX2.in.coforgetech.com/PowerShell/ `
    -Authentication Kerberos -Credential $Cred

Import-PSSession $Session -DisableNameChecking -AllowClobber | Out-Null

# =========================================
# PASSWORD
# =========================================
function Generate-RandomPassword {
    param([int]$Length = 12)
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%"
    -join ((1..$Length) | ForEach-Object {
        $chars[(Get-Random -Maximum $chars.Length)]
    })
}

# =========================================
# DOMAIN CHECK
# =========================================
function Alias-Exists {
    param($Alias)

    $domains=@("IN.COFORGETECH.COM","UK.COFORGETECH.COM","US.COFORGETECH.COM")

    foreach($domain in $domains){
        $check = Get-ADUser -Filter "SamAccountName -eq '$Alias'" -Server $domain -ErrorAction SilentlyContinue
        if($check){ return $true }
    }
    return $false
}

# =========================================
# ✅ FINAL ALIAS FUNCTION (FIXED 🔥)
# =========================================
function Get-UniqueAlias {
    param($FirstName,$LastName)

    $maxEmailLength = 30
    $domain = "@coforge.com"
    $maxAliasLength = $maxEmailLength - $domain.Length

    $FirstName = ($FirstName -replace '\s','').ToLower()
    $LastName  = ($LastName -replace '\s','').ToLower()

    # ✅ FULL NAME
    if ($LastName) {
        $fullAlias = "$FirstName.$LastName"

        if ($fullAlias.Length -le $maxAliasLength -and -not (Alias-Exists $fullAlias)) {
            return $fullAlias
        }
    }

    # ✅ SHORT FORMAT
    if ($LastName) {
        $baseAlias = "$FirstName.$($LastName.Substring(0,1))"
    } else {
        $baseAlias = $FirstName
    }

    if ($baseAlias.Length -gt $maxAliasLength) {
        $baseAlias = $FirstName.Substring(0,$maxAliasLength)
    }

    if (-not (Alias-Exists $baseAlias)) {
        return $baseAlias
    }

    # ✅ NUMBERING
    $count = 1
    while ($true) {

        $newAlias = "$FirstName.$count.$($LastName.Substring(0,1))"

        if ($newAlias.Length -le $maxAliasLength) {
            if (-not (Alias-Exists $newAlias)) {
                return $newAlias
            }
        }

        $count++
    }
}

# =========================================
# MAIN LOOP
# =========================================
foreach ($user in $Users) {

    try {

        $FirstName = $user.FirstName
        $LastName = $user.LastName
        $DisplayName = $user.DisplayName
        $EmpCode = $user.EmpCode
        $OUName = $user.OU
        $License = $user.License

        $OUPath = $OUMap.$OUName
        if (!$OUPath) { throw "Invalid OU: $OUName" }

        $Password = Generate-RandomPassword
        $SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force

        $Alias = Get-UniqueAlias $FirstName $LastName
        $UPN = "$Alias@coforge.com"
        $Routing = "$Alias@ntlgnoida.mail.onmicrosoft.com"

        # ✅ SCREEN LOG
        Write-Host ""
        Write-Host "--------------------------------------------" -ForegroundColor DarkGray
        Write-Host "STARTING USER CREATION" -ForegroundColor Cyan
        Write-Host "Name     : $DisplayName"
        Write-Host "EmpCode  : $EmpCode"
        Write-Host "Alias    : $Alias"
        Write-Host "License  : $License"
        Write-Host "OU       : $OUName"

        # =================================
        # CREATE MAILBOX
        # =================================
        New-RemoteMailbox `
            -Name $DisplayName `
            -FirstName $FirstName `
            -LastName $LastName `
            -Alias $Alias `
            -UserPrincipalName $UPN `
            -OnPremisesOrganizationalUnit $OUPath `
            -Password $SecurePassword `
            -RemoteRoutingAddress $Routing `
            -ResetPasswordOnNextLogon $false `
            -ErrorAction Stop

        Write-Host "✅ Mailbox Created" -ForegroundColor Green

        Start-Sleep 15

        # =================================
        # SET ATTRIBUTES
        # =================================
        $CustomAttr1 = "$EmpCode,P"

        Set-RemoteMailbox `
            -Identity $UPN `
            -CustomAttribute1 $CustomAttr1 `
            -CustomAttribute4 $License `
            -EmailAddressPolicyEnabled $false `
            -ErrorAction Stop

        Write-Host "✅ Attributes Applied" -ForegroundColor Green

        # =================================
        # SUCCESS LOG ✅ (FIXED)
        # =================================
        [PSCustomObject]@{
            DisplayName = $DisplayName
            Alias = $Alias
            Email = $UPN
            EmpCode = $EmpCode
            Password = $Password
            License = $License
            Attribute1 = $CustomAttr1
            Attribute4 = $License
            Status = "SUCCESS"
        } | Export-Csv $SuccessFile -Append -NoTypeInformation

    }
    catch {

        Write-Host "❌ ERROR: $DisplayName" -ForegroundColor Red

        [PSCustomObject]@{
            DisplayName = $DisplayName
            EmpCode = $EmpCode
            Error = $_.Exception.Message
            Status = "FAILED"
        } | Export-Csv $ErrorFile -Append -NoTypeInformation
    }
}

Write-Host ""
Write-Host "============================================="
Write-Host "BULK PROVISIONING COMPLETED ✅"
Write-Host "============================================="

# ✅ CLEANUP
if ($Session){ Remove-PSSession $Session }

exit
