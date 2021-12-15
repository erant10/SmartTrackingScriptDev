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

function CreateAndPopulateCsv {
    if (!(Test-Path $csvPath)) {
        $newcsv = {} | Select "FILE_NAME","SHA" | Export-Csv $csvPath
        Import-Csv $csvPath 
        Write-Output "Created csv file."       
    }
    #populate csv by looping through files and adding to csv
    $Header = @{
        "authorization" = "Bearer $githubAuthToken"
    }
    #get branch sha and use it to get tree with all commit sha and files (should be its own function)
    $getBranchResponse = Invoke-RestMethod https://api.github.com/repos/aaroncorreya/SmartTrackingScriptDev/branches -Headers $header
    Write-Output $getBranchResponse
    $branchSha = $getBranchResponse | ForEach-Object -Process {if ($_.name -eq $branchName) {$_.commit.sha}}
    $treeUrl = "https://api.github.com/repos/aaroncorreya/SmartTrackingScriptDev/git/trees/" + $branchSha + "?recursive=true"
    $getTreeResponse = Invoke-RestMethod $treeUrl -Headers $header
    Write-Output $getTreeResponse

    #add filename,sha to csv object
    $csvTable = @{}
    $getTreeResponse.tree | ForEach-Object -Process {if ($_.path.Substring($_.path.Length-5) -eq ".json") {$csvTable.Add($_.path, $_.sha)}}
    #write csv object to csv file 
    $csvTable.GetEnumerator() | foreach {
        "{0},{1}" -f $_.Key, $_.Value | add-content -path $csvPath
    }
}

#we need token provided by workflow run to push file, not installationtoken, will test later 
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
    #Commit csv file
    Invoke-RestMethod @Parameters
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

function FullDeployment {
    if (Test-Path -Path $Directory) 
    {
        $totalFiles = 0;
        $totalFailed = 0;
        Get-ChildItem -Path $Directory -Recurse -Filter *.json |
        ForEach-Object {
            $path = $_.FullName
	        try {
	            $totalFiles ++
                $templateObject = Get-Content $path | Out-String | ConvertFrom-Json
                if (-not (IsValidResourceType $templateObject))
                {
                    Write-Output "[Warning] Skipping deployment for $path. The file contains resources for content that was not selected for deployment. Please add content type to connection if you want this file to be deployed."
                    return
                }
                $deploymentName = GenerateDeploymentName
                $isSuccess = AttemptDeployment $_.FullName $deploymentName $templateObject
                if (-not $isSuccess) 
                {
                    $totalFailed++
                }
            }
	        catch {
                $totalFailed++
                Write-Host "[Error] An error occurred while trying to deploy file $path. Exception details: $_"
                Write-Host $_.ScriptStackTrace
            }
	    }
        if ($totalFiles -gt 0 -and $totalFailed -gt 0) 
        {
            $err = "$totalFailed of $totalFiles deployments failed."
            Throw $err
        }
    }
    else 
    {
        Write-Output "[Warning] $Directory not found. nothing to deploy"
    }
}

function main() {
    if ($CloudEnv -ne 'AzureCloud') 
    {
        Write-Output "Attempting Sign In to Azure Cloud"
        ConnectAzCloud
    }

    if (-not (Test-Path $csvPath)) {
        Write-Output "Starting Full Deployment for Files in path: $Directory"
        CreateAndPopulateCsv
        #TODO: push csv to repo
        FullDeployment
    }

}

main
#CreateAndPopulateCsv
#PushCsvToRepo