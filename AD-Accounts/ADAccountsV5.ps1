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

Write-Host "================ STARTING SCRIPT ================" -ForegroundColor Cyan

# =========================================
# CHECK PATHS
# =========================================
if (!(Test-Path $CsvFolder)){
    Write-Host "❌ CSV folder not found: $CsvFolder" -ForegroundColor Red
    Read-Host "Press Enter..."
    return
}

if (!(Test-Path $CredPath)){
    Write-Host "❌ Credential file not found: $CredPath" -ForegroundColor Red
    Read-Host "Press Enter..."
    return
}

if (!(Test-Path $OUConfigPath)){
    Write-Host "❌ OU JSON not found: $OUConfigPath" -ForegroundColor Red
    Read-Host "Press Enter..."
    return
}

# =========================================
# LOAD FILES
# =========================================
$Cred = Import-Clixml $CredPath
$OUMap = Get-Content $OUConfigPath -Raw | ConvertFrom-Json

# =========================================
# CREATE LOG FOLDER
# =========================================
if (!(Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

# =========================================
# GET LATEST CSV
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
    Write-Host "❌ CSV is empty" -ForegroundColor Red
    Read-Host "Press Enter..."
    return
}

# =========================================
# CSV VALIDATION
# =========================================
$required = @("FirstName","LastName","DisplayName","EmpCode","OU")
foreach ($col in $required){
    if (-not ($Users[0].PSObject.Properties.Name -contains $col)){
        Write-Host "❌ Missing column: $col" -ForegroundColor Red
        Read-Host "Press Enter..."
        return
    }
}

# =========================================
# LOG FILES
# =========================================
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$SuccessFile = "$LogFolder\success_$timestamp.csv"
$ErrorFile   = "$LogFolder\error_$timestamp.csv"

# =========================================
# PASSWORD FUNCTION
# =========================================
function Generate-RandomPassword {
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%&*"
    -join ((1..12) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
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
# ALIAS LOGIC
# =========================================
function Get-UniqueAlias {
    param($FirstName,$LastName)

    $max = 30 - 12

    $FirstName = ($FirstName -replace '\s','').ToLower()
    $LastName  = if ([string]::IsNullOrWhiteSpace($LastName)) { "" } else { ($LastName -replace '\s','').ToLower() }

    function ok($a){
        if ($a.Length -gt $max){ return $false }
        return -not (Alias-Exists $a)
    }

    if ($LastName){
        $full="$FirstName.$LastName"
        if (ok $full){return $full}

        $i=1
        while($true){
            $n="$FirstName.$i.$LastName"
            if ($n.Length -gt $max){ break }
            if (ok $n){return $n}
            $i++
        }
    }

    $short = if ($LastName){ "$FirstName.$($LastName[0])"} else {$FirstName}

    if ($short.Length -gt $max){
        $short=$FirstName.Substring(0,$max)
    }

    if (ok $short){return $short}

    $i=1
    while($true){
        $n = if ($LastName){ "$FirstName.$i.$($LastName[0])"} else {"$FirstName.$i"}
        if ($n.Length -le $max){
            if (ok $n){return $n}
        }
        $i++
    }
}

# =========================================
# MAIN LOOP
# =========================================
foreach ($user in $Users){

    try{
        Write-Host "-----------------------------"

        $FirstName=$user.FirstName
        $LastName=$user.LastName
        $EmpCode=$user.EmpCode
        $OUKey=$user.OU

        if ([string]::IsNullOrWhiteSpace($FirstName)){
            throw "FirstName missing"
        }

        # ✅ OU MAP
        $OU=$OUMap.$OUKey
        if (-not $OU){
            throw "Invalid OU mapping: $OUKey"
        }

        # ✅ DisplayName
        if ($user.DisplayName){
            $DisplayName=$user.DisplayName.Trim()
        } else {
            $DisplayName= if ($LastName){"$FirstName $LastName"} else {$FirstName}
        }

        if (Get-ADUser -Filter "DisplayName -eq '$DisplayName'" -Credential $Cred -ErrorAction SilentlyContinue){
            $DisplayName="$DisplayName - $EmpCode"
        }

        $Alias=Get-UniqueAlias $FirstName $LastName
        $UPN="$Alias@coforge.com"

        $Password=Generate-RandomPassword
        $Secure=ConvertTo-SecureString $Password -AsPlainText -Force

        Write-Host "➡ $DisplayName ($Alias)" -ForegroundColor Cyan

        New-ADUser `
            -Name $DisplayName `
            -GivenName $FirstName `
            -Surname $LastName `
            -SamAccountName $Alias `
            -UserPrincipalName $UPN `
            -Path $OU `
            -AccountPassword $Secure `
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

    } catch{
        Write-Host "❌ ERROR: $($_.Exception.Message)" -ForegroundColor Red

        [PSCustomObject]@{
            DisplayName="$($user.FirstName) $($user.LastName)"
            EmpCode=$user.EmpCode
            Error=$_.Exception.Message
            Status="FAILED"
        } | Export-Csv $ErrorFile -Append -NoTypeInformation
    }
}

Write-Host ""
Write-Host "✅ COMPLETED ✅" -ForegroundColor Green

Read-Host "Press Enter to exit..."