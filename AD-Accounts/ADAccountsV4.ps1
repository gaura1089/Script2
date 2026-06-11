$ErrorActionPreference = "Stop"

Import-Module ActiveDirectory -ErrorAction Stop

# =========================================
# PATHS
# =========================================
$BaseFolder = "C:\Users\Gaurav.26\OneDrive - Coforge Limited\Documents\AD-Accounts"
$CsvFolder  = "$BaseFolder\bulk_users"
$LogFolder  = "$BaseFolder\Logs"
$OUConfigPath = "$BaseFolder\OU_Config\OUs.json"
$CredPath = "$BaseFolder\Creds\ADCred.xml"

# =========================================
# LOAD CREDENTIAL
# =========================================
if (!(Test-Path $CredPath)){
    Write-Host "❌ Credential file not found: $CredPath" -ForegroundColor Red
    Read-Host "Press Enter..."
    return
}

$Cred = Import-Clixml $CredPath

# =========================================
# LOAD OU JSON
# =========================================
if (!(Test-Path $OUConfigPath)){
    Write-Host "❌ OU JSON not found: $OUConfigPath" -ForegroundColor Red
    Read-Host "Press Enter..."
    return
}

$OUMap = Get-Content $OUConfigPath -Raw | ConvertFrom-Json

# =========================================
# CREATE LOG FOLDER
# =========================================
if (!(Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

# =========================================
# GET CSV
# =========================================
$csvFile = Get-ChildItem -Path $CsvFolder -Filter "*.csv" |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1

if (-not $csvFile){
    Write-Host "❌ No CSV found in: $CsvFolder" -ForegroundColor Red
    Read-Host "Press Enter..."
    return
}

Write-Host "✅ Using CSV: $($csvFile.Name)" -ForegroundColor Yellow

$Users = Import-Csv $csvFile.FullName

if ($Users.Count -eq 0){
    Write-Host "❌ CSV empty" -ForegroundColor Red
    Read-Host "Press Enter..."
    return
}

# ✅ CSV HEADER CHECK
$required = @("FirstName","LastName","DisplayName","EmpCode","OU")
foreach ($col in $required){
    if (-not ($Users[0].PSObject.Properties.Name -contains $col)){
        Write-Host "❌ Missing column: $col" -ForegroundColor Red
        Read-Host "Press Enter..."
        return
    }
}

# ✅ LOG FILES
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$SuccessFile = "$LogFolder\ad_success_$timestamp.csv"
$ErrorFile   = "$LogFolder\ad_error_$timestamp.csv"

# =========================================
# PASSWORD FUNCTION
# =========================================
function Generate-RandomPassword {
    param([int]$Length = 12)
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%&*"
    -join ((1..$Length) | ForEach-Object {
        $chars[(Get-Random -Maximum $chars.Length)]
    })
}

# =========================================
# DOMAIN CHECK
# =========================================
function Alias-Exists {
    param($Alias)

    $domains = @("IN.COFORGETECH.COM","UK.COFORGETECH.COM","US.COFORGETECH.COM")

    foreach($domain in $domains){
        if (Get-ADUser -Filter "SamAccountName -eq '$Alias'" -Server $domain -Credential $Cred -ErrorAction SilentlyContinue){
            return $true
        }
    }
    return $false
}

# =========================================
# ALIAS FUNCTION
# =========================================
function Get-UniqueAlias {
    param($FirstName,$LastName)

    $maxAliasLength = 30 - 12

    $FirstName = ($FirstName -replace '\s','').ToLower()
    $LastName  = if ([string]::IsNullOrWhiteSpace($LastName)) { "" } else { ($LastName -replace '\s','').ToLower() }

    function Free($a){
        if ($a.Length -gt $maxAliasLength){ return $false }
        return -not (Alias-Exists $a)
    }

    if ($LastName){
        $full = "$FirstName.$LastName"
        if (Free $full){ return $full }

        $i=1
        while ($true){
            $new = "$FirstName.$i.$LastName"
            if ($new.Length -gt $maxAliasLength){ break }
            if (Free $new){ return $new }
            $i++
        }
    }

    $short = if ($LastName){ "$FirstName.$($LastName.Substring(0,1))" } else { $FirstName }

    if ($short.Length -gt $maxAliasLength){
        $short = $FirstName.Substring(0,$maxAliasLength)
    }

    if (Free $short){ return $short }

    $i=1
    while ($true){
        $new = if ($LastName){
            "$FirstName.$i.$($LastName.Substring(0,1))"
        } else {
            "$FirstName.$i"
        }

        if ($new.Length -le $maxAliasLength){
            if (Free $new){ return $new }
        }
        $i++
    }
}

# =========================================
# MAIN LOOP (DEBUG ENABLED)
# =========================================
foreach ($user in $Users){

    try{

        Write-Host "-----------------------------"

        $FirstName = $user.FirstName
        $LastName  = $user.LastName
        $EmpCode   = $user.EmpCode
        $OUKey     = $user.OU

        Write-Host "Processing: $FirstName $LastName"

        if ([string]::IsNullOrWhiteSpace($FirstName)){
            throw "FirstName missing"
        }

        # ✅ OU MAPPING
        $OU = $OUMap.$OUKey
        if (-not $OU){
            throw "Invalid OU mapping: $OUKey"
        }

        # ✅ DISPLAY NAME
        if (-not [string]::IsNullOrWhiteSpace($user.DisplayName)){
            $DisplayName = $user.DisplayName.Trim()
        } else {
            $DisplayName = if ($LastName){ "$FirstName $LastName" } else { $FirstName }
        }

        if (Get-ADUser -Filter "DisplayName -eq '$DisplayName'" -Credential $Cred -ErrorAction SilentlyContinue){
            $DisplayName = "$DisplayName - $EmpCode"
        }

        $Alias = Get-UniqueAlias $FirstName $LastName
        $UPN   = "$Alias@coforge.com"

        $Password = Generate-RandomPassword
        $SecurePass = ConvertTo-SecureString $Password -AsPlainText -Force

        Write-Host "➡ Creating: $DisplayName ($Alias)" -ForegroundColor Cyan

        New-ADUser `
            -Name $DisplayName `
            -GivenName $FirstName `
            -Surname $LastName `
            -SamAccountName $Alias `
            -UserPrincipalName $UPN `
            -Path $OU `
            -AccountPassword $SecurePass `
            -Enabled $true `
            -Description "$EmpCode,P" `
            -Credential $Cred `
            -ErrorAction Stop

        Write-Host "✅ SUCCESS" -ForegroundColor Green

        [PSCustomObject]@{
            DisplayName=$DisplayName
            Alias=$Alias
            Email=$UPN
            EmpCode=$EmpCode
            Password=$Password
            Status="SUCCESS"
        } | Export-Csv $SuccessFile -Append -NoTypeInformation

    }
    catch{

        Write-Host "❌ ERROR:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow

        if ($_.InvocationInfo){
            Write-Host "Line: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Cyan
        }

        [PSCustomObject]@{
            DisplayName="$($user.FirstName) $($user.LastName)"
            EmpCode=$user.EmpCode
            Error=$_.Exception.Message
            Status="FAILED"
        } | Export-Csv $ErrorFile -Append -NoTypeInformation
    }
}

Write-Host ""
Write-Host "✅ SCRIPT COMPLETED" -ForegroundColor Green

Read-Host "Press Enter to exit..."