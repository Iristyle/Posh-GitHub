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
    [ValidatePattern('^$|^\w+?:[a-zA-Z0-9\-\.]{1,40}$')]
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

function Set-GitHubUserName
{
  param(
    [Parameter(Mandatory = $true)]
    [string]
    $User
  )

  [Environment]::SetEnvironmentVariable('GITHUB_USERNAME', $User, 'User')
  $Env:GITHUB_USERNAME = $User
}

function Get-GitHubRepositories
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]
    [ValidateScript({ ![string]::IsNullOrEmpty($_) -or `
      ![string]::IsNullOrEmpty($Env:GITHUB_USERNAME) })]
    $User = $Env:GITHUB_USERNAME,

    [Parameter(Mandatory = $false)]
    [string]
    [ValidateSet('all', 'owner', 'member')]
    $Type = 'all',

    [Parameter(Mandatory = $false)]
    [string]
    [ValidateSet('created', 'updated', 'pushed', 'full_name')]
    $Sort = 'full_name',

    [Parameter(Mandatory = $false)]
    [string]
    [ValidateSet('asc', 'desc')]
    [AllowNull()]
    $Direction = $null
  )

  try
  {
    if ($Direction -eq $null)
    {
      $Direction = if ($Sort -eq 'full_name') { 'asc' } else { 'desc' }
    }

    $uri = ("https://api.github.com/users/$User/repos?type=$Type&sort=$Sort" +
      "&direction=$Direction&access_token=${Env:\GITHUB_OAUTH_TOKEN}")

    $global:GITHUB_API_OUTPUT = @()

    do
    {
      $response = Invoke-WebRequest -Uri $uri
      $global:GITHUB_API_OUTPUT += ($response.Content | ConvertFrom-Json)

      if ($matches -ne $null) { $matches.Clear() }
      $uri = $response.Headers.Link -match '\<(.*?)\>; rel="next"' |
        % { $matches[1] }
    } while ($uri -ne $null)


    #TODO: this blows up
    #Write-Verbose $global:GITHUB_API_OUTPUT

    Write-Host "Found $($global:GITHUB_API_OUTPUT.Count) repos for $User"

    $global:GITHUB_API_OUTPUT |
      % {
        $size = if ($_.size -lt 1024) { "$($_.size) KB" }
          else { "$([Math]::Round($_.size, 2)) MB"}
        $pushed = [DateTime]::Parse($_.pushed_at).ToString('g')
        $created = [DateTime]::Parse($_.created_at).ToString('g')

        #$private = if ($_.private) { ' ** Private **' } else { '' }
        $fork = if ($_.fork) { ' [F!]' } else { '' }

        Write-Host ("`n$($_.name)$private$fork : Updated $pushed" +
          " - [$($_.open_issues)] Issues - $size")

        if (![string]::IsNullOrEmpty($_.description))
        {
          Write-Host "`t$($_.description)"
        }
      }
  }
  catch
  {
    Write-Error "An unexpected error occurred $($Error[0])"
  }
}

function Get-GitHubPullRequests
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]
    [ValidateScript({ ![string]::IsNullOrEmpty($_) -or `
      ![string]::IsNullOrEmpty($Env:GITHUB_USERNAME) })]
    $User = $Env:GITHUB_USERNAME,

    [Parameter(Mandatory = $false)]
    [string]
    [ValidateSet('open', 'closed')]
    $State = 'open'
  )

  try
  {
    $totalCount = 0
    $uri = ("https://api.github.com/users/$User/repos" +
      "?access_token=${Env:\GITHUB_OAUTH_TOKEN}")

    $global:GITHUB_API_OUTPUT = @{
      RepoList = @();
      Repos = @();
    }

    do
    {
      $response = Invoke-WebRequest -Uri $uri
      $global:GITHUB_API_OUTPUT.RepoList += ($response.Content | ConvertFrom-Json)

      if ($matches -ne $null) { $matches.Clear() }
      $uri = $response.Headers.Link -match '\<(.*?)\>; rel="next"' |
        % { $matches[1] }
    } while ($uri -ne $null)

    #TODO: this blows up
    #Write-Verbose $global:GITHUB_API_OUTPUT

    $forks = $global:GITHUB_API_OUTPUT.RepoList | ? { $_.fork }
    Write-Host "Found $($forks.Count) forked repos for $User"

    $forks |
      % {
        $repo = Invoke-RestMethod -Uri $_.url

        $uri = ("https://api.github.com/repos/$($repo.parent.full_name)/pulls" +
          "?state=$State&access_token=${Env:\GITHUB_OAUTH_TOKEN}")
        $pulls = Invoke-RestMethod -Uri $uri

        $global:GITHUB_API_OUTPUT.Repos += @{ Repo = $repo; Pulls = $pulls }

        $pulls |
          ? { $_.user.login -eq $User } |
          % {
            $totalCount++
            $updated = if ([string]::IsNullOrEmpty($_.updated_at)) { $_.created_at }
              else { $_.updated_at }
            $updated = [DateTime]::Parse($updated).ToString('g')
            Write-Host "`n$($repo.name) pull $($_.number) - $($_.title) - $updated"
            Write-Host "`t$($_.issue_url)"
          }
      }

    Write-Host "`nFound $totalCount open pull requests for $User"
  }
  catch
  {
    Write-Error "An unexpected error occurred $($Error[0])"
  }
}

function Update-PoshGitHub
{
  #$null if we can't find module (not sure how that happens, but just in case!)
  $installedPath = Get-Module Posh-GitHub |
    Select -ExpandProperty Path |
    Split-Path

  Push-Location $installedPath

  #DANGER - be safe and abort as git reset --hard could do damage in wrong spot
  if (($installedPath -eq $null) -or ((Get-Location).Path -ne $installedPath))
  {
    Pop-Location
    throw "Could not find Posh-GitHub module / reset path - Update aborted!"
    return
  }

  Write-Host "Found Posh-GitHub module at $installedPath"
  git reset --hard HEAD | Out-Null
  git pull | Write-Host
  Pop-Location
  Remove-Module Posh-GitHub
  Import-Module (Join-Path $installedPath 'Posh-GitHub.psm1')
}

Export-ModuleMember -Function  New-GitHubOAuthToken, New-GitHubPullRequest,
  Get-GitHubIssues, Get-GitHubEvents, Get-GitHubRepositories, Update-PoshGitHub,
  Get-GitHubPullRequests
