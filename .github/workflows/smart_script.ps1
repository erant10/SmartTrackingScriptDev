#read variables from json for dev
$json = (Get-Content "C:\One\SmartTrackingScriptDev\environment_df.json" -Raw) | ConvertFrom-Json
Write-Output $json
## Globals ##
$CloudEnv = $json.cloudEnv
$ResourceGroupName = $json.resourceGroupName
$WorkspaceName = $json.workspaceName
$Directory = $json.directory
$Creds = $json.creds
$contentTypes = $json.contentTypes
$contentTypeMapping = @{
    "AnalyticsRule"=@("Microsoft.OperationalInsights/workspaces/providers/alertRules", "Microsoft.OperationalInsights/workspaces/providers/alertRules/actions");
    "AutomationRule"=@("Microsoft.OperationalInsights/workspaces/providers/automationRules");
    "HuntingQuery"=@("Microsoft.OperationalInsights/workspaces/savedSearches");
    "Parser"=@("Microsoft.OperationalInsights/workspaces/savedSearches");
    "Playbook"=@("Microsoft.Web/connections", "Microsoft.Logic/workflows", "Microsoft.Web/customApis");
    "Workbook"=@("Microsoft.Insights/workbooks");
    "Metadata"=@("Microsoft.OperationalInsights/workspaces/providers/metadata");
}
$csvPath = ".github\workflows\tracking_table.csv"
$githubAuthToken = $json.githubAuthToken
$githubRepository = $json.githubRepository
$branchName = "main" #change to variable passed through workflow
$manualDeployment = $json.manualDeployment

if ([string]::IsNullOrEmpty($contentTypes)) {
    $contentTypes = "AnalyticsRule,Metadata"
}

if (-not ($contentTypes.contains("Metadata"))) {
    $contentTypes += ",Metadata"
}

$resourceTypes = $contentTypes.Split(",") | ForEach-Object { $contentTypeMapping[$_] } | ForEach-Object { $_.ToLower() }
$MaxRetries = 3
$secondsBetweenAttempts = 5

function CreateCsv() {
    if (Test-Path $csvPath) {
        Clear-Content -Path $csvPath
    }  
    Add-Content -Path $csvPath -Value "FileName, CommitSha"
}

function WriteTableToCsv($shaTable) {
    if (Test-Path $csvPath) {
        Clear-Content -Path $csvPath
    }  
    Add-Content -Path $csvPath -Value "FileName, CommitSha"
    $shaTable.GetEnumerator() | ForEach-Object {
        "{0},{1}" -f $_.Key, $_.Value | add-content -path $csvPath
    }
}

function GetCommitShaTable {
    $Header = @{
        "authorization" = "Bearer $githubAuthToken"
    }
    #get branch sha and use it to get tree with all commit shas and files 
    $branchResponse = Invoke-RestMethod https://api.github.com/repos/$githubRepository/branches/$branchName -Headers $header
    $treeUrl = "https://api.github.com/repos/$githubRepository/git/trees/" + $branchResponse.commit.sha + "?recursive=true"
    $getTreeResponse = Invoke-RestMethod $treeUrl -Headers $header
    $shaTable = @{}
    $getTreeResponse.tree | ForEach-Object {
        if ($_.path.Substring($_.path.Length-5) -eq ".json") 
        {
            #needs to be $workplace in real implementation
            $truePath = ($Directory + "\" + $_.path).Replace("/", "\")
            $shaTable.Add($truePath, $_.sha)
        }
    }
    return $shaTable
}

function PushCsvToRepo {
    #if exists, we need sha of csv file before pushing updated file. If new, no need 
    $Header = @{
        "authorization" = "Bearer $githubAuthToken"
    }
    $path = ".github/workflows/tracking_table.csv"
    Write-Output $path
    $createFileUrl = "https://api.github.com/repos/aaroncorreya/SmartTrackingScriptDev/contents/$path"
    $content = Get-Content -Path $csvPath | Out-String
    $encodedContent = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
    Write-Output $encodedContent
    $body = @{
        message = "trackingTable.csv created."
        content = $encodedContent
        branch = $branchName
    }

    $Parameters = @{
        Method      = "PUT"
        Uri         = $createFileUrl
        Headers     = $Header
        Body        = $body | ConvertTo-Json
    }
    Invoke-RestMethod @Parameters
}

function ReadCsvToTable {
    $mytable = Import-Csv -Path $csvPath
    $HashTable=@{}
    foreach($r in $mytable)
    {
        $HashTable[$r.FileName]=$r.CommitSha
    }   
    return $HashTable    
}

function AttemptAzLogin($psCredential, $tenantId, $cloudEnv) {
    $maxLoginRetries = 3
    $delayInSeconds = 30
    $retryCount = 1
    $stopTrying = $false
    do {
        try {
            Connect-AzAccount -ServicePrincipal -Tenant $tenantId -Credential $psCredential -Environment $cloudEnv | out-null;
            Write-Host "Login Successful"
            $stopTrying = $true
        }
        catch {
            if ($retryCount -ge $maxLoginRetries) {
                Write-Host "Login failed after $maxLoginRetries attempts."
                $stopTrying = $true
            }
            else {
                Write-Host "Login attempt failed, retrying in $delayInSeconds seconds."
                Start-Sleep -Seconds $delayInSeconds
                $retryCount++
            }
        }
    }
    while (-not $stopTrying)
}

function ConnectAzCloud {
    $RawCreds = $Creds | ConvertFrom-Json

    Clear-AzContext -Scope Process;
    Clear-AzContext -Scope CurrentUser -Force -ErrorAction SilentlyContinue;
    
    Add-AzEnvironment `
        -Name $CloudEnv `
        -ActiveDirectoryEndpoint $RawCreds.activeDirectoryEndpointUrl `
        -ResourceManagerEndpoint $RawCreds.resourceManagerEndpointUrl `
        -ActiveDirectoryServiceEndpointResourceId $RawCreds.activeDirectoryServiceEndpointResourceId `
        -GraphEndpoint $RawCreds.graphEndpointUrl | out-null;

    $servicePrincipalKey = ConvertTo-SecureString $RawCreds.clientSecret.replace("'", "''") -AsPlainText -Force
    $psCredential = New-Object System.Management.Automation.PSCredential($RawCreds.clientId, $servicePrincipalKey)

    AttemptAzLogin $psCredential $RawCreds.tenantId $CloudEnv
    Set-AzContext -Tenant $RawCreds.tenantId | out-null;
}

function IsValidTemplate($path, $templateObject) {
    Try {
        if (DoesContainWorkspaceParam $templateObject) {
            Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $path -workspace $WorkspaceName
        }
        else {
            Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $path
        }

        return $true
    }
    Catch {
        Write-Host "[Warning] The file $path is not valid: $_"
        return $false
    }
}

function IsRetryable($deploymentName) {
    $retryableStatusCodes = "Conflict","TooManyRequests","InternalServerError","DeploymentActive"
    Try {
        $deploymentResult = Get-AzResourceGroupDeploymentOperation -DeploymentName $deploymentName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        return $retryableStatusCodes -contains $deploymentResult.StatusCode
    }
    Catch {
        return $false
    }
}
function IsValidResourceType($template) {
    $isAllowedResources = $true
    $template.resources | ForEach-Object { 
        $isAllowedResources = $resourceTypes.contains($_.type.ToLower()) -and $isAllowedResources
    }
    return $isAllowedResources
}

function DoesContainWorkspaceParam($templateObject) {
    $templateObject.parameters.PSobject.Properties.Name -contains "workspace"
}

function AttemptDeployment($path, $deploymentName, $templateObject) {
    Write-Host "[Info] Deploying $path with deployment name $deploymentName"

    $isValid = IsValidTemplate $path $templateObject
    if (-not $isValid) {
        return $false
    }
    $isSuccess = $false
    $currentAttempt = 0
    While (($currentAttempt -lt $MaxRetries) -and (-not $isSuccess)) 
    {
        $currentAttempt ++
        Try 
        {
            if (DoesContainWorkspaceParam $templateObject) 
            {
                New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $path -workspace $workspaceName -ErrorAction Stop | Out-Host
            }
            else 
            {
                New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $path -ErrorAction Stop | Out-Host
            }
            
            $isSuccess = $true
        }
        Catch [Exception] 
        {
            $err = $_
            if (-not (IsRetryable $deploymentName)) 
            {
                Write-Host "[Warning] Failed to deploy $path with error: $err"
                break
            }
            else 
            {
                if ($currentAttempt -le $MaxRetries) 
                {
                    Write-Host "[Warning] Failed to deploy $path with error: $err. Retrying in $secondsBetweenAttempts seconds..."
                    Start-Sleep -Seconds $secondsBetweenAttempts
                }
                else
                {
                    Write-Host "[Warning] Failed to deploy $path after $currentAttempt attempts with error: $err"
                }
            }
        }
    }
    return $isSuccess
}

function GenerateDeploymentName() {
    $randomId = [guid]::NewGuid()
    return "Sentinel_Deployment_$randomId"
}

function CheckFullDeployment() {
    $flag = $false
    if ((-not (Test-Path $csvPath)) -or ($manualDeployment -eq "true")) {
        $flag = $true
    }
    return $flag 
}

function Deployment($fullDeploymentFlag, $localCsvTable, $remoteShaTable) {
    Write-Output "Starting Deployment for Files in path: $Directory"
    if (Test-Path -Path $Directory) 
    {
        $totalFiles = 0;
        $totalFailed = 0;
        Get-ChildItem -Path $Directory -Recurse -Filter *.json |
        ForEach-Object {
            $path = $_.FullName
            $templateObject = Get-Content $path | Out-String | ConvertFrom-Json
            #put this into try catch
            try {
                if (-not (IsValidResourceType $templateObject))
                {
                    Write-Output "[Warning] Skipping deployment for $path. The file contains resources for content that was not selected for deployment. Please add content type to connection if you want this file to be deployed."
                    return
                }                
            }
            catch {
                Write-Host "[Error] An error occurred while trying to deploy file $path. Exception details: $_"
            }
        
            if ($fullDeploymentFlag) {
                $result = FullDeployment $path $templateObject
                # if (-not $result.isSuccess) {$totalFailed++}
            }
            else {
                $result = SmartDeployment $localCsvTable $remoteShaTable $path $templateObject
                $localCsvTable = $result.csvTable
            }
            #convert to global variables
            if ($result.isSuccess -eq $false) {
                $totalFailed++
            }
            if (-not $result.skip) {
                $totalFiles++
            }
	    }
        if ($totalFiles -gt 0 -and $totalFailed -gt 0) 
        {
            $err = "$totalFailed of $totalFiles deployments failed."
            Throw $err
        }
        return $localCsvTable
    }
    else 
    {
        Write-Output "[Warning] $Directory not found. nothing to deploy"
    }
}

function FullDeployment($path, $templateObject) {
    try {
        $deploymentName = GenerateDeploymentName
        $isSuccess = AttemptDeployment $path $deploymentName $templateObject
        $result = @{
            skip = $false
            isSuccess = $isSuccess
        }        
        return $result
    }
    catch {
        Write-Host "[Error] An error occurred while trying to deploy file $path. Exception details: $_"
        Write-Host $_.ScriptStackTrace
    }   
}

function SmartDeployment($localCsvTable, $remoteShaTable, $path, $templateObject) {
	try {
        $skip = $false
	    $existingSha = $localCsvTable[$path]
        $remoteSha = $remoteShaTable[$path]
        if ((!$existingSha) -or ($existingSha -ne $remoteSha)) {
            $deploymentName = GenerateDeploymentName
            $isSuccess = AttemptDeployment $path $deploymentName $templateObject    
            $localCsvTable[$path] = $remoteSha
        }
        else {
            $skip = $true
            $isSuccess = $null  
        }
        $result = @{
            skip = $skip
            isSuccess = $isSuccess
            csvTable = $localCsvTable
        }
        return $result
    }
    catch {
        Write-Host "[Error] An error occurred while trying to deploy file $path. Exception details: $_"
        Write-Host $_.ScriptStackTrace
    }
}

function main() {
    if ($CloudEnv -ne 'AzureCloud') 
    {
        Write-Output "Attempting Sign In to Azure Cloud"
        ConnectAzCloud
    }

    $fullDeploymentFlag = CheckFullDeployment
    Write-Output $fullDeploymentFlag

    if (-not (Test-Path $csvPath)) {
        Write-Output "Creating csv and conducting full deployment."
        $remoteShaTable = GetCommitShaTable
        WriteTableToCsv($remoteShaTable)
        # PushCsvToRepo
        Deployment $fullDeploymentFlag $null $null
    }
    else {
        $localCsvTable = ReadCsvToTable
        $remoteShaTable = GetCommitShaTable
        Write-Output "Local Csv Table"
        Write-Output $localCsvTable
        Write-Output "Remote Csv Table"
        Write-Output $remoteShaTable
        $updatedCsvTable = Deployment $fullDeploymentFlag $localCsvTable $remoteShaTable
        WriteTableToCsv($updatedCsvTable)
        #PushCsvToRepo
    }
}

main

