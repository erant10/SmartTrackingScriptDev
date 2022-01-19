$githubAuthToken = $Env:githubAuthToken
$githubRepository = $Env:GITHUB_REPOSITORY
$refName = $Env:GITHUB_REF
$branchName = $refName.Replace("refs/heads/", "")
#$branchName = $Env:branch
$workspace = $Env:GITHUB_WORKSPACE + "\"
$sourceControlId = $Env:sourceControlId 
$csvPath = ".github\workflows\tracking_table_$sourceControlId.csv"
$global:localCsvTablefinal = @{}

$header = @{
    "authorization" = "Bearer $githubAuthToken"
    "Content-Type" = "application/json"
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

#Converts hashtable to string that can be set as content when pushing csv file
function ConvertTableToString {
    $output = "FileName1, CommitSha1`n"
    $global:localCsvTablefinal.GetEnumerator() | ForEach-Object {
        $output += "{0},{1}`n" -f $_.Key, $_.Value
    }
    return $output
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
    return $getTreeResponse.tree |  Where-Object { $_.path -eq "tracking_table_$sourceControlId.csv" }
}

#Creates a table using the reponse from the tree api, creates a table 
function GetCommitShaTable($getTreeResponse) {
    $shaTable = @{}
    $getTreeResponse.tree | ForEach-Object {
        if ([System.IO.Path]::GetExtension($_.path) -eq ".json")
        {
            $truePath =  $_.path.Replace("/", "\")
            $shaTable.Add($truePath, $_.sha)
            Write-Output $truePath
            Write-Output $_.sha
        }
    }
    #Write-Output $shaTable
    return $shaTable
}

#Pushes new/updated csv file to the user's repository. If updating file, will need csv commit sha. 
#TODO: Add source control id to tracking_table name.
function PushCsvToRepo($getTreeResponse) {
    $path = "tracking_table_$sourceControlId.csv"
    $sha = GetCsvCommitSha $getTreeResponse
    $createFileUrl = "https://api.github.com/repos/$githubRepository/contents/$path"
    $content = ConvertTableToString
    $encodedContent = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
    # $encodedContent = "SGVsbG8gd29ybGQgbmV3"
    Write-Output $encodedContent
    $body = @{
        message = "trackingTable.csv created."
        content = $encodedContent
        branch = $branchName
        sha = $sha.sha
    }

    $Parameters = @{
        Method      = "PUT"
        Uri         = $createFileUrl
        Headers     = $header
        Body        = $body | ConvertTo-Json
    }
    Write-Output $Parameters | Out-String
    Invoke-RestMethod @Parameters
}

function main {
    Write-Output $githubRepository
    $tree = GetGithubTree
    $shaTable = GetCommitShaTable $tree 
    $global:localCsvTablefinal = $shaTable
    PushCsvToRepo $tree
    Write-Output "SHA TABLE"
    Write-Output $shaTable
}

main
# $shaTable = @{}
# $tree = GetGithubTree 
# Write-Output $tree
# $shaTable = GetCommitShaTable $tree
# Write-Output $shaTable
# $sha = GetCsvCommitSha $tree
# Write-Output $sha
