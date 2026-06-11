Import-Module ActiveDirectory -ErrorAction Stop

# =========================================
# PATHS
# =========================================
$BaseFolder = "C:\Users\Gaurav.26\OneDrive - Coforge Limited\Documents\AD-Accounts"
$CsvFolder  = "$BaseFolder\bulk_users"
$LogFolder  = "$BaseFolder\Logs"

if (!(Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

# ✅ GET LATEST CSV
$csvFile = Get-ChildItem -Path $CsvFolder -Filter "*.csv" |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1

if (-not $csvFile) {
    Write-Host "❌ No CSV found" -ForegroundColor Red
    exit
}

Write-Host "Using CSV: $($csvFile.Name)" -ForegroundColor Yellow

$Users = Import-Csv $csvFile.FullName

# ✅ VALIDATE CSV
$required = @("FirstName","LastName","DisplayName","EmpCode","OU")
foreach ($col in $required){
    if (-not ($Users[0].PSObject.Properties.Name -contains $col)){
        throw "Missing column in CSV: $col"
    }
}

# ✅ LOG FILES
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$SuccessFile = "$LogFolder\ad_success_$timestamp.csv"
$ErrorFile   = "$LogFolder\ad_error_$timestamp.csv"

# =========================================
# RANDOM PASSWORD ✅🔥
# =========================================
function Generate-RandomPassword {
    param([int]$Length = 12)

    $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lower = 'abcdefghijklmnopqrstuvwxyz'
    $digits = '0123456789'
    $special = '!@#$%&*'

    $all = ($upper + $lower + $digits + $special).ToCharArray()

    $rand = New-Object System.Random

    $password = @(
        $upper[$rand.Next(0,$upper.Length)]
        $lower[$rand.Next(0,$lower.Length)]
        $digits[$rand.Next(0,$digits.Length)]
        $special[$rand.Next(0,$special.Length)]
    )

    for ($i = $password.Count; $i -lt $Length; $i++) {
        $password += $all[$rand.Next(0,$all.Length)]
    }

    -join ($password | Sort-Object {Get-Random})
}

# =========================================
# DOMAIN CHECK
# =========================================
function Alias-Exists {
    param($Alias)

    $domains = @("IN.COFORGETECH.COM","UK.COFORGETECH.COM","US.COFORGETECH.COM")

    foreach($domain in $domains){
        if (Get-ADUser -Filter "SamAccountName -eq '$Alias'" -Server $domain -ErrorAction SilentlyContinue){
            return $true
        }
    }
    return $false
}

# =========================================
# ✅ FINAL ALIAS FUNCTION
# =========================================
function Get-UniqueAlias {
    param($FirstName,$LastName)

    $maxAliasLength = 30 - 12

    $FirstName = ($FirstName -replace '\s','').ToLower()

    if (:IsNullOrWhiteSpace($LastName)) {
        $LastName = ""
    } else {
        $LastName = ($LastName -replace '\s','').ToLower()
    }

    function Free($a){
        if ($a.Length -gt $maxAliasLength){ return $false }
        return -not (Alias-Exists $a)
    }

    # ✅ FULL
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

    # ✅ SHORT
    if ($LastName){
        $short = "$FirstName.$($LastName.Substring(0,1))"
    } else {
        $short = $FirstName
    }

    if ($short.Length -gt $maxAliasLength){
        $short = $FirstName.Substring(0,$maxAliasLength)
    }

    if (Free $short){ return $short }

    # ✅ NUMBERING
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
# MAIN LOOP
# =========================================
foreach ($user in $Users){

    try{

        $FirstName  = $user.FirstName
        $LastName   = $user.LastName
        $EmpCode    = $user.EmpCode
        $OU         = $user.OU

        if (:IsNullOrWhiteSpace($FirstName)){
            throw "FirstName missing"
        }

        # ✅ DISPLAY NAME (CSV priority)
        if (-not :IsNullOrWhiteSpace($user.DisplayName)){
            $DisplayName = $user.DisplayName.Trim()
        } else {
            $DisplayName = if ($LastName){ "$FirstName $LastName" } else { $FirstName }
        }

        # ✅ DISPLAY NAME CONFLICT
        if (Get-ADUser -Filter "DisplayName -eq '$DisplayName'" -ErrorAction SilentlyContinue){
            $DisplayName = "$DisplayName - $EmpCode"
        }

        # ✅ ALIAS
        $Alias = Get-UniqueAlias $FirstName $LastName
        $UPN   = "$Alias@coforge.com"

        # ✅ PASSWORD
        $Password = Generate-RandomPassword
        $SecurePass = ConvertTo-SecureString $Password -AsPlainText -Force

        Write-Host "Creating: $DisplayName ($Alias)" -ForegroundColor Cyan

        # ✅ CREATE USER
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
            -ErrorAction Stop

        Write-Host "✅ SUCCESS" -ForegroundColor Green

        [PSCustomObject]@{
            DisplayName = $DisplayName
            Alias       = $Alias
            Email       = $UPN
            EmpCode     = $EmpCode
            Password    = $Password   # ✅ IMPORTANT
            Status      = "SUCCESS"
        } | Export-Csv $SuccessFile -Append -NoTypeInformation

    }
    catch{

        Write-Host "❌ ERROR: $($user.FirstName) $($user.LastName)" -ForegroundColor Red

        [PSCustomObject]@{
            DisplayName = "$($user.FirstName) $($user.LastName)"
            EmpCode     = $user.EmpCode
            Error       = $_.Exception.Message
            Status      = "FAILED"
        } | Export-Csv $ErrorFile -Append -NoTypeInformation
    }
}

Write-Host ""
Write-Host "✅ AD USER CREATION COMPLETED" -ForegroundColor Green