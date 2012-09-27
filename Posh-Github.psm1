function Get-CurrentDirectory
{
  $thisName = $MyInvocation.MyCommand.Name
  [IO.Path]::GetDirectoryName((Get-Content function:$thisName).File)
}

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
    $NoEnvironmentVariable = $false,

    [Parameter(Mandatory = $false)]
    [string]
    $Note = 'Command line API token'
  )

  try
  {
    $postData = @{
      scopes = @('repo');
      note = $Note
    }

    $params = @{
      Uri = 'https://api.github.com/authorizations';
      Method = 'POST';
      Headers = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String(
          [Text.Encoding]::ASCII.GetBytes("$($userName):$($password)"));
      }
      ContentType = 'application/json';
      Body = (ConvertTo-Json $postData -Compress)
    }
    $global:GITHUB_API_OUTPUT = Invoke-RestMethod @params
    Write-Verbose $global:GITHUB_API_OUTPUT

    $token = $GITHUB_API_OUTPUT | Select -ExpandProperty Token
    Write-Host "New OAuth token is $token"

    if (!$NoEnvironmentVariable)
    {
      $Env:GITHUB_OAUTH_TOKEN = $token
      [Environment]::SetEnvironmentVariable('GITHUB_OAUTH_TOKEN', $token, 'User')
    }
  }
  catch
  {
    Write-Error "An unexpected error occurred (bad user/password?) $($Error[0])"
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
    $uri = ("https://api.github.com/repos/$Owner/$Repository/issues" +
     "?state=$state&access_token=${Env:\GITHUB_OAUTH_TOKEN}")

    #no way to set Accept header with Invoke-RestMethod
    #http://connect.microsoft.com/PowerShell/feedback/details/757249/invoke-restmethod-accept-header#tabs
    #-Headers @{ Accept = 'application/vnd.github.v3.text+json' }

    Write-Host "Requesting issues for $Owner/$Repository"
    $global:GITHUB_API_OUTPUT = Invoke-RestMethod -Uri $uri
    Write-Verbose $global:GITHUB_API_OUTPUT

    $global:GITHUB_API_OUTPUT |
      % { Write-Host "Issue $($_.Number): $($_.Title)" }
  }
  catch
  {
    Write-Error "An unexpected error occurred $($Error[0])"
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

  $postData = @{ head = $Head; base = $Base }
  switch ($PsCmdlet.ParameterSetName)
  {
    'Issue' {
      $postData.issue = $IssueId
    }
    'Title' {
      $postData.title = $Title
      $postData.body = $Body
    }
  }

  Write-Host "Sending pull request to $Owner/$Repository from $Head"

  try
  {
    $params = @{
      Uri = ("https://api.github.com/repos/$Owner/$Repository/pulls" +
        "?access_token=${Env:\GITHUB_OAUTH_TOKEN}");
      Method = 'POST';
      ContentType = 'application/json';
      Body = (ConvertTo-Json $postData -Compress);
    }

    $global:GITHUB_API_OUTPUT = Invoke-RestMethod @params
    Write-Verbose $global:GITHUB_API_OUTPUT

    $url = $global:GITHUB_API_OUTPUT | Select -ExpandProperty 'html_url'
    Write-Host "Pull request sent to $url"
  }
  catch
  {
    Write-Error "An unexpected error occurred $($Error[0])"
  }
}

function Get-GitHubEvents
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]
    [ValidateScript({ ![string]::IsNullOrEmpty($_) -or `
      ![string]::IsNullOrEmpty($Env:GITHUB_USERNAME) })]
    $User = $Env:GITHUB_USERNAME
  )

  try
  {
    $uri = ("https://api.github.com/users/$User/events" +
      "?access_token=${Env:\GITHUB_OAUTH_TOKEN}")

    $global:GITHUB_API_OUTPUT = Invoke-RestMethod -Uri $uri
    #TODO: this blows up
    #Write-Verbose $global:GITHUB_API_OUTPUT

    $global:GITHUB_API_OUTPUT[($global:GITHUB_API_OUTPUT.Length - 1)..0] |
      % {
        $date = [DateTime]::Parse($_.created_at).ToString('g')
        $type = $_.type.Replace('Event', '')
        $firstLine = if ($type -eq 'Gist' )
          { "$($_.payload.gist.action) Gist at $($_.payload.gist.html_url)"}
        elseif ($type -eq 'PullRequest' )
          { "$($_.payload.action) Pull $($_.payload.number) for $($_.repo.name)" }
        else
          { "$type for $($_.repo.name)" }

        #TODO: consider adding comment handling $_.payload.comment.body when
        #type is 'CommitComment' - but need to be able to use accept header to
        #get plaintext instead of markdown

        $description = if ($type -eq 'Gist' )
          { "$($_.payload.gist.description)"}
        else
          { $_.payload.commits.message }

        Write-Host "`n$($date): $firstLine"
        if (![string]::IsNullOrEmpty($description))
        {
          $description -split "`n" | % { Write-Host "`t$_" }
        }
      }
  }
  catch
  {
    Write-Error "An unexpected error occurred $($Error[0])"
  }
}

function Update-PoshGitHub
{
  $installedPath = Get-Module Posh-GitHub |
    Select -ExpandProperty Path |
    Split-Path

  Write-Host "Found Post-GitHub module at $installedPath"
  Push-Location $installedPath
  git reset --hard HEAD | Out-Null
  git pull
  Pop-Location
  Remove-Module Posh-GitHub
  Import-Module (Join-Path $installedPath 'Posh-GitHub.psm1')
}

Export-ModuleMember -Function  New-GitHubOAuthToken, New-GitHubPullRequest,
  Get-GitHubIssues, Get-GitHubEvents, Update-PoshGitHub
