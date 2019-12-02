﻿using module ..\Include.psm1

param(
    [TimeSpan]$StatSpan,
    [PSCustomObject]$Config #to be removed
)

$PoolFileName = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName
$Wallets = $Config.Pools.$PoolFileName.Wallets #to be removed
$Worker = [String]$Config.Pools.$PoolFileName.Worker #to be removed
$PasswordSuffix = [String]$Config.Pools.$PoolFileName.PasswordSuffix #to be removed

# Guaranteed payout currencies
$Payout_Currencies = @("BTC", "DOGE", "LTC") | Where-Object { $Wallets.$_ }
if (-not $Payout_Currencies) { 
    Write-Log -Level Verbose "Cannot mine on pool ($PoolFileName) - no wallet address specified. "
    return
}

$PoolRegions = "eu", "us"
$PoolAPIStatusUri = "http://blockmasters.co/api/status"
$PoolAPICurrenciesUri = "http://blockmasters.co/api/currencies"
$RetryCount = 3
$RetryDelay = 2

while (-not ($APIStatusResponse -and $APICurrenciesResponse) -and $RetryCount -gt 0) { 
    try {
        if (-not $APIStatusResponse) { $APIStatusResponse = Invoke-RestMethod $PoolAPIStatusUri -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop }
        if (-not $APICurrenciesResponse) { $APICurrenciesResponse = Invoke-RestMethod $PoolAPICurrenciesUri -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop }
    }
    catch { }
    if (-not ($APIStatusResponse -and $APICurrenciesResponse)) { 
        Start-Sleep -Seconds $RetryDelay
        $RetryCount--
    }
}

if (-not ($APIStatusResponse -and $APICurrenciesResponse)) { 
    Write-Log -Level Warn "Pool API ($PoolFileName) has failed. "
    return
}

if (($APIStatusResponse | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Measure-Object Name).Count -lt 1) { 
    Write-Log -Level Warn "Pool API ($PoolFileName) [StatusUri] returned nothing. "
    return
}

if (($APICurrenciesResponse | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Measure-Object Name).Count -lt 1) { 
    Write-Log -Level Warn "Pool API ($PoolFileName) [CurrenciesUri] returned nothing. "
    return
}

$Payout_Currencies = (@($Payout_Currencies) + @($APICurrenciesResponse | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name)) | Where-Object { $Wallets.$_ } | Sort-Object -Unique
if (-not $Payout_Currencies) { 
    Write-Log -Level Verbose "Cannot mine on pool ($PoolFileName) - no wallet address specified. "
    return
}

$PoolName = "$($PoolFileName)-Algo"
Write-Log -Level Verbose "Processing pool data ($PoolName). "
$APIStatusResponse | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | Where-Object { $APIStatusResponse.$_.hashrate -gt 0 } | Where-Object { $APIStatusResponse.$_.mbtc_mh_factor -gt 0 } | ForEach-Object {
    $PoolHost = "blockmasters.co"
    $Port = [Int]$APIStatusResponse.$_.port
    $Algorithm = [String]$APIStatusResponse.$_.name
    $Algorithm_Norm = ""; $CoinName = ""; $CurrencySymbol = ""
    if ($APIStatusResponse.$_.coins -eq 1) {
        $CurrencySymbols = @($APICurrenciesResponse | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | Where-Object { $APICurrenciesResponse.$_.algo -eq $Algorithm })
        if ($CurrencySymbols.Count -eq 1) { 
            $CurrencySymbol = [String]($CurrencySymbols -split "-" | Select-Object -First 1)
            $CoinName = Get-CoinName $APICurrenciesResponse.$CurrencySymbols.Name
        }
    }
    $Algorithm_Norm = Get-Algorithm $Algorithm

    $Workers = [Int]$APIStatusResponse.$_.workers
    $Fee = [Decimal]($APIStatusResponse.$_.Fees / 100)

    $Divisor = 1000000 <#check#> * [Double]$APIStatusResponse.$_.mbtc_mh_factor

    if ((Get-Stat -Name "$($PoolName)_$($Algorithm_Norm)_Profit") -eq $null) { $Stat = Set-Stat -Name "$($PoolName)_$($Algorithm_Norm)_Profit" -Value ($APIStatusResponse.$_.estimate_last24h / $Divisor) -Duration (New-TimeSpan -Days 1) } 
    else { $Stat = Set-Stat -Name "$($PoolName)_$($Algorithm_Norm)_Profit" -Value ($APIStatusResponse.$_.estimate_current / $Divisor) -Duration $StatSpan -ChangeDetection $true } 

    try { $EstimateCorrection = [Decimal](($APIStatusResponse.$_.actual_last24h / 1000) / $APIStatusResponse.$_.estimate_last24h) }
    catch { $EstimateCorrection = [Decimal]1 }

    $PoolRegions | ForEach-Object { 
        $Region = $_
        $Region_Norm = Get-Region $Region

        $Payout_Currencies | ForEach-Object { 
            [PSCustomObject]@{ 
                Name               = $PoolName
                Algorithm          = $Algorithm_Norm
                CoinName           = $CoinName
                CurrencySymbol     = $CurrencySymbol
                Price              = $Stat.Live
                StablePrice        = $Stat.Week
                MarginOfError      = $Stat.Week_Fluctuation
                Protocol           = "stratum+tcp"
                Host               = "$(if ($Region -eq "eu") { "eu." })$PoolHost"
                Port               = $Port
                User               = [String]$Wallets.$_
                Pass               = "ID=$Worker,c=$_,$($PasswordSuffix.Algorithm."*")$($PasswordSuffix.Algorithm.$Algorithm_Norm)$($PasswordSuffix.CoinName."*")$($PasswordSuffix.CoinName.$CoinName)"
                Region             = $Region_Norm
                SSL                = $false
                Updated            = $Stat.Updated
                Fee                = $Fee
                Workers            = $Workers
                EstimateCorrection = $EstimateCorrection
            }
        }
    }
}

$PoolName = "$($PoolFileName)-Coin"
Write-Log -Level Verbose "Processing pool data ($PoolName). "
$APICurrenciesResponse | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | Where-Object { $APICurrenciesResponse.$_.hashrate -gt 0 } | ForEach-Object { 
    $APICurrenciesResponse.$_ | Add-Member Symbol $_ -ErrorAction Ignore
    $Algorithm = [String]$APICurrenciesResponse.$_.algo

    # Not all algorithms are always exposed in API
    if ($APIStatusResponse.$Algorithm.mbtc_mh_factor -gt 0) { 
        $PoolHost = "blockmasters.co"
        $Port = [Int]$APICurrenciesResponse.$_.port
        $CoinName = Get-CoinName $APICurrenciesResponse.$_.name
        $CurrencySymbol = "$(($APICurrenciesResponse.$_.symbol | Select-Object -Index 0) -split '-' | Select-Object -Index 0)"
        $Algorithm_Norm = Get-Algorithm $Algorithm
        $Workers = [Int]$APICurrenciesResponse.$_.workers
        $Fee = [Decimal]($APIStatusResponse.$Algorithm.Fees / 100)

        [Int64]$Block = $APICurrenciesResponse.$_.height
        if (-not $Block) { [Int64]$Block = $APICurrenciesResponse.$_.lastblock }

        $Divisor = 1000000000 <#check#> * [Double]$APIStatusResponse.$Algorithm.mbtc_mh_factor

        $Stat = Set-Stat -Name "$($PoolName)_$($CurrencySymbol)-$($Algorithm_Norm)_Profit" -Value ($APICurrenciesResponse.$_.estimate / $Divisor) -Duration $StatSpan -ChangeDetection $true

        try { $EstimateCorrection = [Decimal](($APIStatusResponse.$Algorithm.actual_last24h / 1000) / $APIStatusResponse.$Algorithm.estimate_last24h) } 
        catch { $EstimateCorrection = [Decimal]1 }

        $PoolRegions | ForEach-Object { 
            $Region = $_
            $Region_Norm = Get-Region $Region

            $Payout_Currencies | ForEach-Object { 
                [PSCustomObject]@{ 
                    Name               = $PoolName
                    Algorithm          = $Algorithm_Norm
                    CoinName           = $CoinName
                    CurrencySymbol     = $CurrencySymbol
                    Price              = $Stat.Live
                    StablePrice        = $Stat.Week
                    MarginOfError      = $Stat.Week_Fluctuation
                    Protocol           = "stratum+tcp"
                    Host               = "$(if ($Region -eq "eu") {"eu."})$PoolHost"
                    Port               = $Port
                    User               = [String]$Wallets.$_
                    Pass               = "ID=$Worker,c=$_,mc=$CurrencySymbol$($PasswordSuffix.Algorithm."*")$($PasswordSuffix.Algorithm.$Algorithm_Norm)$($PasswordSuffix.CoinName."*")$($PasswordSuffix.CoinName.$CoinName)"
                    Region             = $Region_Norm
                    SSL                = $false
                    Updated            = $Stat.Updated
                    Fee                = $Fee
                    Workers            = $Workers
                    EstimateCorrection = $EstimateCorrection
                }

                if ($Algorithm_Norm -eq "Ethash" -and $Block -gt 0) { 
                    [PSCustomObject]@{ 
                        Name               = $PoolName
                        Algorithm          = "$Algorithm_Norm-$([Math]::Ceiling((Get-EthashSize $Block)/1GB))GB"
                        CoinName           = $CoinName
                        CurrencySymbol     = $CurrencySymbol
                        Price              = $Stat.Live
                        StablePrice        = $Stat.Week
                        MarginOfError      = $Stat.Week_Fluctuation
                        Protocol           = "stratum+tcp"
                        Host               = "$(if ($Region -eq "eu") {"eu."})$PoolHost"
                        Port               = $Port
                        User               = [String]$Wallets.$_
                        Pass               = "ID=$Worker,c=$_,mc=$CurrencySymbol$($PasswordSuffix.Algorithm."*")$($PasswordSuffix.Algorithm.$Algorithm_Norm)$($PasswordSuffix.CoinName."*")$($PasswordSuffix.CoinName.$CoinName)"
                        Region             = $Region_Norm
                        SSL                = $false
                        Updated            = $Stat.Updated
                        Fee                = $Fee
                        Workers            = $Workers
                        EstimateCorrection = $EstimateCorrection
                    }
                }
            }
        }
    }
}
