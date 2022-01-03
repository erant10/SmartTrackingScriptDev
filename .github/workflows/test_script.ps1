$csvPath = ".github\workflows\tracking_table.csv"
$githubAuthToken = $Env:githubAuthToken
$githubRepository = $Env:GITHUB_REPOSITORY
$refName = $Env:GITHUB_REF
$branchName = $refName.Replace("refs/heads/", "")
$workspace = $Env:GITHUB_WORKSPACE

function CreateAndPopulateCsv {
    if (!(Test-Path $csvPath)) {
        Add-Content -Path $csvPath -Value "FileName, CommitSha"
        Write-Output "Created csv file."       
    }
    $shaTable = GetCommitShaTable
    Write-Output $shaTable
    #write all filename, sha to csv file  
    $shaTable.GetEnumerator() | ForEach-Object {
        "{0},{1}" -f $_.Key, $_.Value | add-content -path $csvPath
    }
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
            #needs to be $workspace in real implementation
            $truePath = ($workspace + "\" + $_.path).Replace("/", "\")
            $shaTable.Add($truePath, $_.sha)
        }
    }
    return $shaTable
}

#we need token provided by workflow run to push file, not installationtoken, will test later 
function PushCsvToRepo {
    #if exists, we need sha of csv file before pushing updated file. If new, no need 
    $Header = @{
        "authorization" = "Bearer $githubAuthToken"
    }
    $path = ".github/workflows/tracking_table.csv"
    Write-Output $path
    $createFileUrl = "https://api.github.com/repos/$githubRepository/contents/$path"
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

function main {
    Write-Output $githubRepository
    $shaTable = GetCommitShaTable
    WriteTableToCsv $shaTable
    # CreateAndPopulateCsv
    PushCsvToRepo

    Get-ChildItem -Path $Directory -Recurse -Filter *.json |
    ForEach-Object {
        $path = $_.FullName
        Write-Output $path
    }
    Write-Output $workspace
}

main 