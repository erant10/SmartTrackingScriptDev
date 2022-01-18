$githubAuthToken = $Env:githubAuthToken
$githubRepository = $Env:GITHUB_REPOSITORY
$refName = $Env:GITHUB_REF
$branchName = $refName.Replace("refs/heads/", "")
#$branchName = $Env:branch
$workspace = $Env:GITHUB_WORKSPACE + "\"
$sourceControlId = $Env:sourceControlId 
$csvPath = ".github\workflows\tracking_table_$sourceControlId.csv"

$header = @{
    "authorization" = "Bearer $githubAuthToken"
}

#Writes sha dictionary object to csv file. Will delete any pre-existing content before writing.  
function WriteTableToCsv($shaTable) {
    if (Test-Path $csvPath) {
        Clear-Content -Path $csvPath
    }  
    Add-Content -Path $csvPath -Value "FileName, CommitSha"
    $shaTable.GetEnumerator() | ForEach-Object {
        "{0},{1}" -f $_.Key, $_.Value | add-content -path $csvPath
    }
}

#Gets all files and commit shas using Get Trees API 
function GetGithubTree {
    $branchResponse = Invoke-RestMethod https://api.github.com/repos/$githubRepository/branches/$branchName -Headers $header
    $treeUrl = "https://api.github.com/repos/$githubRepository/git/trees/" + $branchResponse.commit.sha + "?recursive=true"
    $getTreeResponse = Invoke-RestMethod $treeUrl -Headers $header
    return $getTreeResponse
}

#Gets blob commit sha of the csv file, used when updating csv file to repo 
function GetCsvCommitSha($getTreeResponse) {
    return $getTreeResponse.tree |  Where-Object { $_.path -eq ".github/workflows/tracking_table_$sourceControlId.csv" }
}

#Creates a table using the reponse from the tree api, creates a table 
function GetCommitShaTable($getTreeResponse) {
    $shaTable = @{}
    $getTreeResponse.tree | ForEach-Object {
        #if ($_.path.Substring($_.path.Length-5) -eq ".json") 
        if ([System.IO.Path]::GetExtension($_.path) -eq ".json")
        {
            #$truePath = ($workspace + "\" + $_.path).Replace("/", "\")
            $truePath =  $_.path.Replace("/", "\")
            $shaTable.Add($truePath, $_.sha)
        }
    }
    return $shaTable
}

#Pushes new/updated csv file to the user's repository. If updating file, will need csv commit sha. 
#TODO: Add source control id to tracking_table name.
function PushCsvToRepo($getTreeResponse) {
    $path = ".github/workflows/tracking_table_$sourceControlId.csv"
    Write-Output $path
    $sha = GetCsvCommitSha $getTreeResponse
    $createFileUrl = "https://api.github.com/repos/$githubRepository/contents/$path"
    $content = Get-Content -Path $csvPath | Out-String
    $encodedContent = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
    Write-Output $encodedContent
    $body = @{
        message = "trackingTable.csv created."
        content = $encodedContent
        branch = $branchName
        sha = $sha
    }

    $Parameters = @{
        Method      = "PUT"
        Uri         = $createFileUrl
        Headers     = $header
        Body        = $body | ConvertTo-Json
    }
    Invoke-RestMethod @Parameters
}

function main {
    Write-Output $githubRepository
    $tree = GetGithubTree
    $shaTable = GetCommitShaTable $tree 
    WriteTableToCsv $shaTable
    PushCsvToRepo $tree
    Write-Output "SHA TABLE"
    Write-Output $shaTable

    #TODO: Make sure that the paths are the same when testing locally and remotely
    Get-ChildItem -Path $workspace -Recurse -Filter *.json |
    ForEach-Object {
        $path = $_.FullName.Replace($workspace, "")
        Write-Output $path
    }
    Write-Output $workspace
}

# main
$table = GetCommitShaTable
Write-Output $table 