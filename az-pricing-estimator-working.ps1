# Azure Hybrid Benefit Cost Impact Calculator
# This script calculates the cost difference between VMs with and without Azure Hybrid Benefit for Windows Server

# Azure Hybrid Benefit Cost Impact Calculator
# This script calculates the cost difference between VMs with and without Azure Hybrid Benefit for Windows Server

$baseUrl = "https://prices.azure.com/api/retail/prices"

# Define your VM inventory by region
# Each region contains an array of VM configurations with SKU name and quantity
$vmInventory = @{
    "westus2" = @(
        @{ skuName = "Standard_D2s_v5"; quantity = 5 },
        @{ skuName = "Standard_D4s_v5"; quantity = 3 },
        @{ skuName = "Standard_E2s_v5"; quantity = 2 },
        @{ skuName = "Standard_B2s"; quantity = 10 }
    )
    "eastus2" = @(
        @{ skuName = "Standard_D2s_v5"; quantity = 8 },
        @{ skuName = "Standard_D4s_v5"; quantity = 2 },
        @{ skuName = "Standard_E4s_v5"; quantity = 1 }
    )
    "northeurope" = @(
        @{ skuName = "Standard_D2s_v5"; quantity = 3 },
        @{ skuName = "Standard_D8s_v5"; quantity = 1 }
    )
}

$usageScenarios = @{
    "Production" = @{
        Description = "24/7 production workload"
        HoursPerDay = 24
        DaysPerMonth = 30
    }
}

function Get-MonthlyCost {
    param(
        [decimal]$HourlyRate,
        [int]$HoursPerDay,
        [int]$DaysPerMonth
    )
    
    $totalHours = $HoursPerDay * $DaysPerMonth
    $monthlyCost = $HourlyRate * $totalHours
    
    return [PSCustomObject]@{
        TotalHours = $totalHours
        MonthlyCost = [math]::Round($monthlyCost, 2)
    }
}

function Get-WindowsServerPricing {
    param(
        [string]$SKU,
        [string]$Region
    )
    
    $allSkuFilter = "?`$filter=serviceName eq 'Virtual Machines' and armRegionName eq '$Region' and skuName eq '$SKU'"
    $allSkuUrl = "$baseUrl$allSkuFilter"
    
    try {
        $allSkuResponse = Invoke-RestMethod -Uri $allSkuUrl -Method Get
        
        if ($allSkuResponse.Items.Count -eq 0) {
            Write-Warning "No pricing data found for $SKU in $Region"
            return $null
        }
        
        $hourlyPricing = $allSkuResponse.Items | Where-Object { 
            $_.unitOfMeasure -eq "1 Hour" -and 
            $_.unitPrice -lt 10
        }
        
        if ($hourlyPricing.Count -eq 0) {
            Write-Warning "No hourly pricing found for $SKU in $Region"
            return $null
        }
        
        $windowsPricing = $hourlyPricing | Where-Object { 
            $_.productName -like "*Windows*"
        } | Sort-Object unitPrice -Descending | Select-Object -First 1
        
        $computePricing = $hourlyPricing | Where-Object { 
            $_.productName -notlike "*Windows*"
        } | Sort-Object unitPrice | Select-Object -First 1
        
        if ($windowsPricing -and $computePricing) {
            $windowsLicenseCost = $windowsPricing.unitPrice - $computePricing.unitPrice
            
            return [PSCustomObject]@{
                SKU = $SKU
                Region = $Region
                ComputeOnlyPrice = $computePricing.unitPrice
                WindowsFullPrice = $windowsPricing.unitPrice
                WindowsLicenseCost = [math]::Round($windowsLicenseCost, 4)
                Currency = $windowsPricing.currencyCode
                EffectiveDate = $windowsPricing.effectiveStartDate
                ComputeProduct = $computePricing.productName
                WindowsProduct = $windowsPricing.productName
            }
        } else {
            Write-Warning "Could not find both Windows and compute-only pricing for $SKU in $Region"
            return $null
        }
        
    } catch {
        Write-Warning "Error retrieving Windows Server pricing for $SKU in $Region : $_"
        return $null
    }
}

$allResults = @()

Write-Host "=== Azure Hybrid Benefit Cost Impact Analysis ===" -ForegroundColor Green
Write-Host "Analyzing Windows Server licensing costs for your entire VM inventory" -ForegroundColor Gray

# Calculate total inventory summary
$totalVMsInInventory = 0
$inventorySummary = @()

foreach ($region in $vmInventory.Keys) {
    foreach ($vm in $vmInventory[$region]) {
        $totalVMsInInventory += $vm.quantity
        $inventorySummary += [PSCustomObject]@{
            Region = $region
            SKU = $vm.skuName
            Quantity = $vm.quantity
        }
    }
}

Write-Host "`n--- VM Inventory Summary ---" -ForegroundColor Cyan
Write-Host "Total VMs in inventory: $totalVMsInInventory"
Write-Host "Regions: $($vmInventory.Keys -join ', ')"
Write-Host "Unique SKUs: $(($inventorySummary | Select-Object -Unique SKU).Count)"
Write-Host "`nInventory breakdown:"
$inventorySummary | Group-Object Region | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Group.Count) SKU types, $(($_.Group | Measure-Object Quantity -Sum).Sum) total VMs"
}

foreach ($region in $vmInventory.Keys) {
    Write-Host "`n=== Region: $region ===" -ForegroundColor Yellow
    $regionVMs = $vmInventory[$region]
    
    foreach ($vm in $regionVMs) {
        $sku = $vm.skuName
        $quantity = $vm.quantity
        
        Write-Host "`n--- Analyzing SKU: $sku (Quantity: $quantity) ---" -ForegroundColor Cyan
        
        $pricingData = Get-WindowsServerPricing -SKU $sku -Region $region
        
        if ($pricingData) {
            Write-Host "✓ Found pricing data for $sku in $region" -ForegroundColor Green
            Write-Host "  Compute-only (with Hybrid Benefit): $($pricingData.ComputeOnlyPrice) $($pricingData.Currency)/hour"
            Write-Host "  Full Windows price (without Hybrid Benefit): $($pricingData.WindowsFullPrice) $($pricingData.Currency)/hour"
            Write-Host "  Windows license cost: $($pricingData.WindowsLicenseCost) $($pricingData.Currency)/hour" -ForegroundColor Red
            
            Write-Host "`n  Cost Impact Analysis for $quantity VMs:" -ForegroundColor White
            
            foreach ($scenarioName in $usageScenarios.Keys) {
                $scenario = $usageScenarios[$scenarioName]
                
                # Calculate costs per VM
                $hybridBenefitCost = Get-MonthlyCost -HourlyRate $pricingData.ComputeOnlyPrice -HoursPerDay $scenario.HoursPerDay -DaysPerMonth $scenario.DaysPerMonth
                $fullWindowsCost = Get-MonthlyCost -HourlyRate $pricingData.WindowsFullPrice -HoursPerDay $scenario.HoursPerDay -DaysPerMonth $scenario.DaysPerMonth
                $windowsLicenseMonthlyCost = Get-MonthlyCost -HourlyRate $pricingData.WindowsLicenseCost -HoursPerDay $scenario.HoursPerDay -DaysPerMonth $scenario.DaysPerMonth
                
                # Calculate total costs for all VMs of this SKU
                $totalHybridBenefitCost = $hybridBenefitCost.MonthlyCost * $quantity
                $totalFullWindowsCost = $fullWindowsCost.MonthlyCost * $quantity
                $totalWindowsLicenseCost = $windowsLicenseMonthlyCost.MonthlyCost * $quantity
                
                Write-Host "    $scenarioName ($($scenario.Description)):"
                Write-Host "      Hours per month per VM: $($hybridBenefitCost.TotalHours)"
                Write-Host "      Cost per VM with Hybrid Benefit: $($hybridBenefitCost.MonthlyCost) $($pricingData.Currency)/month"
                Write-Host "      Cost per VM without Hybrid Benefit: $($fullWindowsCost.MonthlyCost) $($pricingData.Currency)/month"
                Write-Host "      Windows license cost per VM: $($windowsLicenseMonthlyCost.MonthlyCost) $($pricingData.Currency)/month" -ForegroundColor Red
                Write-Host "      " -NoNewline
                Write-Host "TOTAL for $quantity VMs:" -ForegroundColor Yellow
                Write-Host "        Total cost with Hybrid Benefit: $([math]::Round($totalHybridBenefitCost, 2)) $($pricingData.Currency)/month"
                Write-Host "        Total cost without Hybrid Benefit: $([math]::Round($totalFullWindowsCost, 2)) $($pricingData.Currency)/month"
                Write-Host "        Total Windows license cost: $([math]::Round($totalWindowsLicenseCost, 2)) $($pricingData.Currency)/month" -ForegroundColor Red
                Write-Host "        Total cost increase if HB expires: +$([math]::Round($totalWindowsLicenseCost, 2)) $($pricingData.Currency)/month" -ForegroundColor Red
                
                # Store results for summary
                $allResults += [PSCustomObject]@{
                    Region = $region
                    SKU = $sku
                    Quantity = $quantity
                    Scenario = $scenarioName
                    ScenarioDescription = $scenario.Description
                    HoursPerMonth = $hybridBenefitCost.TotalHours
                    HourlyComputeOnlyPrice = $pricingData.ComputeOnlyPrice
                    HourlyWindowsFullPrice = $pricingData.WindowsFullPrice
                    HourlyWindowsLicenseCost = $pricingData.WindowsLicenseCost
                    MonthlyCostWithHybridBenefitPerVM = $hybridBenefitCost.MonthlyCost
                    MonthlyCostWithoutHybridBenefitPerVM = $fullWindowsCost.MonthlyCost
                    MonthlyWindowsLicenseCostPerVM = $windowsLicenseMonthlyCost.MonthlyCost
                    TotalMonthlyCostWithHybridBenefit = [math]::Round($totalHybridBenefitCost, 2)
                    TotalMonthlyCostWithoutHybridBenefit = [math]::Round($totalFullWindowsCost, 2)
                    TotalMonthlyWindowsLicenseCost = [math]::Round($totalWindowsLicenseCost, 2)
                    TotalCostIncreaseIfHybridBenefitExpires = [math]::Round($totalWindowsLicenseCost, 2)
                    Currency = $pricingData.Currency
                    EffectiveDate = $pricingData.EffectiveDate
                    ComputeProduct = $pricingData.ComputeProduct
                    WindowsProduct = $pricingData.WindowsProduct
                }
            }
        } else {
            Write-Host "✗ No pricing data found for $sku in $region" -ForegroundColor Red
        }
    }
}

Write-Host "`n`n=== AZURE HYBRID BENEFIT COST IMPACT SUMMARY ===" -ForegroundColor Magenta

if ($allResults.Count -gt 0) {
    Write-Host "Total VM configurations analyzed: $($allResults.Count)" -ForegroundColor White
    Write-Host "Total VMs in inventory: $totalVMsInInventory" -ForegroundColor White
    
    # Calculate totals across entire inventory
    $totalMonthlyCostWithHB = ($allResults | Measure-Object TotalMonthlyCostWithHybridBenefit -Sum).Sum
    $totalMonthlyCostWithoutHB = ($allResults | Measure-Object TotalMonthlyCostWithoutHybridBenefit -Sum).Sum
    $totalMonthlyWindowsLicenseCost = ($allResults | Measure-Object TotalMonthlyWindowsLicenseCost -Sum).Sum
    
    Write-Host "`n--- Overall Financial Impact for Entire Inventory ---" -ForegroundColor Yellow
    Write-Host "Total monthly cost with Hybrid Benefit: $([math]::Round($totalMonthlyCostWithHB, 2)) $($allResults[0].Currency)" -ForegroundColor Green
    Write-Host "Total monthly cost without Hybrid Benefit: $([math]::Round($totalMonthlyCostWithoutHB, 2)) $($allResults[0].Currency)" -ForegroundColor Red
    Write-Host "Total monthly Windows license cost: $([math]::Round($totalMonthlyWindowsLicenseCost, 2)) $($allResults[0].Currency)" -ForegroundColor Red
    Write-Host "Monthly cost increase if Hybrid Benefit expires: +$([math]::Round($totalMonthlyWindowsLicenseCost, 2)) $($allResults[0].Currency)" -ForegroundColor Red
    
    # Annual projection
    $annualCostIncrease = $totalMonthlyWindowsLicenseCost * 12
    Write-Host "Annual cost increase if Hybrid Benefit expires: +$([math]::Round($annualCostIncrease, 2)) $($allResults[0].Currency)" -ForegroundColor Red
    
    # Cost increase percentage
    $costIncreasePercentage = ($totalMonthlyWindowsLicenseCost / $totalMonthlyCostWithHB) * 100
    Write-Host "This represents a $([math]::Round($costIncreasePercentage, 1))% increase in your total VM costs" -ForegroundColor Red
    
    # Summary by region
    Write-Host "`n--- Cost Impact by Region ---" -ForegroundColor Cyan
    $allResults | Group-Object Region | ForEach-Object {
        $regionResults = $_.Group
        $regionWindowsLicenseCost = ($regionResults | Measure-Object TotalMonthlyWindowsLicenseCost -Sum).Sum
        $regionVMCount = ($regionResults | Measure-Object Quantity -Sum).Sum
        
        Write-Host "$($_.Name) - $regionVMCount VMs:"
        Write-Host "  Monthly Windows license cost: $([math]::Round($regionWindowsLicenseCost, 2)) $($regionResults[0].Currency)"
        Write-Host "  Annual Windows license cost: $([math]::Round($regionWindowsLicenseCost * 12, 2)) $($regionResults[0].Currency)"
        Write-Host "  Average cost per VM: $([math]::Round($regionWindowsLicenseCost / $regionVMCount, 2)) $($regionResults[0].Currency)/month per VM"
    }
    
    # Summary by SKU
    Write-Host "`n--- Cost Impact by SKU ---" -ForegroundColor Cyan
    $allResults | Group-Object SKU | ForEach-Object {
        $skuResults = $_.Group
        $skuWindowsLicenseCost = ($skuResults | Measure-Object TotalMonthlyWindowsLicenseCost -Sum).Sum
        $skuVMCount = ($skuResults | Measure-Object Quantity -Sum).Sum
        
        Write-Host "$($_.Name) - $skuVMCount VMs across $(($skuResults | Select-Object -Unique Region).Count) regions:"
        Write-Host "  Monthly Windows license cost: $([math]::Round($skuWindowsLicenseCost, 2)) $($skuResults[0].Currency)"
        Write-Host "  Annual Windows license cost: $([math]::Round($skuWindowsLicenseCost * 12, 2)) $($skuResults[0].Currency)"
        Write-Host "  Average cost per VM: $([math]::Round($skuWindowsLicenseCost / $skuVMCount, 2)) $($skuResults[0].Currency)/month per VM"
    }
    
    # Top cost contributors
    Write-Host "`n--- Top Cost Contributors ---" -ForegroundColor Cyan
    $allResults | Sort-Object TotalMonthlyWindowsLicenseCost -Descending | Select-Object -First 5 | ForEach-Object {
        Write-Host "$($_.Region) - $($_.SKU) (Qty: $($_.Quantity)): $($_.TotalMonthlyWindowsLicenseCost) $($_.Currency)/month"
    }
    
    # Export results to CSV
    $csvPath = "azure-hybrid-benefit-inventory-impact-$(Get-Date -Format 'yyyy-MM-dd-HHmm').csv"
    $allResults | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Host "`n--- Export Complete ---" -ForegroundColor Green
    Write-Host "Detailed results exported to: $csvPath"
    
    # Decision making summary
    Write-Host "`n--- Decision Making Summary ---" -ForegroundColor Yellow
    Write-Host "For your inventory of $totalVMsInInventory VMs across $($vmInventory.Keys.Count) regions:"
    Write-Host "• If you do not renew Azure Hybrid Benefit, your Windows Server costs will increase by $([math]::Round($totalMonthlyWindowsLicenseCost, 2)) $($allResults[0].Currency)/month"
    Write-Host "• Annual cost increase: $([math]::Round($annualCostIncrease, 2)) $($allResults[0].Currency)/year"
    Write-Host "• This represents a $([math]::Round($costIncreasePercentage, 1))% increase in your total VM costs"
    Write-Host "• Average cost increase per VM: $([math]::Round($totalMonthlyWindowsLicenseCost / $totalVMsInInventory, 2)) $($allResults[0].Currency)/month per VM"
    
    # ROI calculation helper
    Write-Host "`n--- ROI Calculation Helper ---" -ForegroundColor Magenta
    Write-Host "To justify renewing your Windows Server licenses instead of paying Azure licensing:"
    Write-Host "• Your annual Windows Server license renewal cost should be LESS than $([math]::Round($annualCostIncrease, 2)) $($allResults[0].Currency)"
    Write-Host "• Break-even point: If license renewal costs more than $([math]::Round($annualCostIncrease, 2)) $($allResults[0].Currency)/year, it is cheaper to pay Azure licensing"
    
} else {
    Write-Host "No pricing data was successfully retrieved. Please check:" -ForegroundColor Red
    Write-Host "Internet connectivity and Azure Pricing API availability"
}

Write-Host "`n--- Notes ---" -ForegroundColor Gray
Write-Host "Prices are current as of $(Get-Date)"
Write-Host "All prices exclude storage, networking, and other costs"
Write-Host "Azure Hybrid Benefit allows you to use your existing Windows Server licenses"
Write-Host "This analysis helps you understand the financial impact of not renewing your Windows Server licenses"
Write-Host "Update the vmInventory hashtable at the top of the script to reflect your actual VM inventory"
