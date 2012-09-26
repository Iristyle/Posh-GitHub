function New-GitHubOAuthToken
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]
    $UserName,

    [Parameter(Mandatory = $true)]
    [string]
    $Password,

    [Parameter(Mandatory = $false)]
    [switch]
    $SetEnvironmentVariable = $true,

    [Parameter(Mandatory = $false)]
    [string]
    $Note = 'Command line API token'
  )

  try
  {
    $client = (New-Object Net.WebClient)
    $uri = 'https://api.github.com/authorizations'
    $client.Headers.Add('Authorization',
      'Basic ' + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$($userName):$($password)")))
    $client.Headers.Add('Content-Type', 'application/json')

    $json = "{`"scopes`": [ `"repo`" ],`"note`": `"$note`"}"
    $apiOutput = $client.UploadString($uri, $json)
    Write-Host $apiOutput
    $token = $apiOutput -match '"token":"(.*?)",' | % { $matches[1] }
    Write-Host "New OAuth token is $token"

    if ($SetEnvironmentVariable)
    {
      $Env:GITHUB_OAUTH_TOKEN = $token
      [Environment]::SetEnvironmentVariable('GITHUB_OAUTH_TOKEN', $token, 'User')
    }
  }
  catch
  {
    Write-Host 'An unexpected error occurred - likely bad username / password'
  }
}

function Get-GitHubIssues
{
  [CmdletBinding()]
  param(
   [Parameter(Mandatory = $true)]
   [string]
   $Owner,

   [Parameter(Mandatory = $true)]
   [string]
   $Repository,

   [Parameter(Mandatory = $false)]
   [ValidateSet('open', 'closed')]
   $State
 )

  try
  {
    $client = (New-Object Net.WebClient)
    $uri = ("https://api.github.com/repos/$Owner/$Repository/issues" +
     "?state=$state&access_token=${Env:\GITHUB_OAUTH_TOKEN}")

    $client.Headers.Add('Accept', 'application/vnd.github.v3.text+json')

    Write-Host "Requesting issues for $Owner/$Repository"
    $apiOutput = $client.DownloadString($uri)
    $Env:Github_Api_Output = $apiOutput
    $titles = $apiOutput |
      Select-String -Pattern '"title":"([^"]*?)",' -AllMatches
    $numbers = $apiOutput |
      Select-String -Pattern '"number":(\d+),' -AllMatches

    0..($numbers.Matches.Count - 1) |
    % {
      $number = $numbers.Matches[$_].Groups[1].Value
      $title = $titles.Matches[$_].Groups[1].Value
      Write-Host "Issue $number : $title"
    }
  }
  catch
  {
    Write-Host "An unexpected error occurred $($Error[0])"
  }
}

function New-GitHubPullRequest
{
  [CmdletBinding(DefaultParameterSetName='Title')]
  param(
    [Parameter(ParameterSetName='Issue', Mandatory = $true)]
    [int]
    $IssueId,

    [Parameter(ParameterSetName='Title', Mandatory = $true)]
    [string]
    $Title,

    [Parameter(ParameterSetName='Title', Mandatory = $false)]
    [string]
    $Body,

    [Parameter(Mandatory = $false)]
    [string]
    $Base = 'master',

    [Parameter(Mandatory = $false)]
    [string]
    $Owner = $null,

    [Parameter(Mandatory = $false)]
    [string]
    $Repository = $null,

    [Parameter(Mandatory = $false)]
    [string]
    [ValidatePattern('^$|^\w+?:[a-zA-Z0-9\-]{1,40}$')]
    [AllowNull()]
    $Head = ''
  )

  if ([string]::IsNullOrEmpty($Owner) -and [string]::IsNullOrEmpty($Repository))
  {
    #try to sniff out the repo based on 'upstream'
    if ($matches -ne $null) { $matches.Clear() }
    git remote -v show |
      ? { $_ -match 'upstream\t.*github.com\/(.*)\/(.*) \((fetch|push)\)' } |
      Out-Null

    if ($matches.Count -eq 0)
    {
      throw "No upstream remote define, so couldn't determine where to send pull"
    }

    $Owner = $matches[1]
    $Repository = $matches[2]
  }
  elseif ([string]::IsNullOrEmpty($Owner) -or [string]::IsNullOrEmpty($Repository))
  {
    throw "An Owner and Repository must be specified together"
  }

  if ([string]::IsNullOrEmpty($Head))
  {
    $localUser = git remote -v show |
      ? { $_ -match 'origin\t.*github.com\/(.*)\/.* \((fetch|push)\)' } |
      % { $matches[1] } |
      Select -First 1

    $branchName = git symbolic-ref -q HEAD |
      % { $_ -replace 'refs/heads/', ''}

    $Head = "$($localUser):$($branchName)"
  }
  # TODO: find a way to determine if the specified HEAD is valid??

  $uri = ("https://api.github.com/repos/$Owner/$Repository/pulls" +
    "?access_token=${Env:\GITHUB_OAUTH_TOKEN}")

  switch ($PsCmdlet.ParameterSetName)
  {
    'Issue' {
      $json = "{`"issue`":`"$IssueId`",`"head`":`"$Head`",`"base`":`"$Base`"}"
    }
    'Title' {
      $json = "{`"title`":`"$title`",`"body`":`"$body`",`"head`":`"$Head`",`"base`":`"$Base`"}"
    }
  }

  Write-Host "Sending pull request to $Owner/$Repository from $Head"
  Write-Verbose $uri
  Write-Verbose $json

  $client = New-Object Net.WebClient
  $client.Headers.Add('Content-Type', 'application/json')
  $client.UploadString($uri, $json)
}

Export-ModuleMember -Function  New-GitHubOAuthToken, New-GitHubPullRequest,
  Get-GitHubIssues
