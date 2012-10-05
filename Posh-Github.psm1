#Requires -Version 3.0

function Get-CurrentDirectory
{
  $thisName = $MyInvocation.MyCommand.Name
  [IO.Path]::GetDirectoryName((Get-Content function:$thisName).File)
}

function GetRemotes
{
  $remotes = @{}
  #try to sniff out the repo based on 'upstream'
  if ($matches -ne $null) { $matches.Clear() }
  $gitRemotes = git remote -v show

  $pattern = '^(.*)?\t.*github.com\/(.*)\/(.*) \((fetch|push)\)'
  $gitRemotes |
    Select-String -Pattern $pattern -AllMatches |
    % {
      $repo = @{
        Name = $_.Matches.Groups[1].Value;
        Owner = $_.Matches.Groups[2].Value;
        Repository = ($_.Matches.Groups[3].Value -replace '\.git$', '');
      }

      if (!$remotes.ContainsKey($repo.Name))
      {
        $remotes."$($repo.Name)" = $repo;
      }
    }

  return $remotes
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

function Get-GitHubOAuthTokens
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]
    $UserName,

    [Parameter(Mandatory = $true)]
    [string]
    $Password
  )

  try
  {
    $params = @{
      Uri = 'https://api.github.com/authorizations';
      Headers = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String(
          [Text.Encoding]::ASCII.GetBytes("$($userName):$($password)"));
      }
    }
    $global:GITHUB_API_OUTPUT = Invoke-RestMethod @params
    #Write-Verbose $global:GITHUB_API_OUTPUT

    $global:GITHUB_API_OUTPUT |
      % {
        $date = [DateTime]::Parse($_.created_at).ToString('g')
        Write-Host "`n$($_.app.name) - Created $date"
        Write-Host "`t$($_.token)`n`t$($_.app.url)"
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
    $remotes = GetRemotes
    if (!($remotes.upstream))
    {
      throw "No remote named 'upstream' defined, so cannot determine where to send pull"
    }

    $Owner = $remotes.upstream.owner
    $Repository = $remotes.upstream.repository
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

function Set-GitHubOrganization
{
  param(
    [Parameter(Mandatory = $true)]
    [string]
    $Organization
  )

  [Environment]::SetEnvironmentVariable('GITHUB_ORG', $Organization, 'User')
  $Env:GITHUB_USERNAME = $Organization
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

function GetUserPullRequests($User, $State)
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

function Get-GitHubPullRequests
{
  [CmdletBinding(DefaultParameterSetName='user')]
  param(
    [Parameter(Mandatory = $false, ParameterSetName='user')]
    [string]
    $User = $Env:GITHUB_USERNAME,

    [Parameter(Mandatory = $false)]
    [string]
    [ValidateSet('open', 'closed')]
    $State = 'open'
  )

  try
  {
    switch ($PsCmdlet.ParameterSetName)
    {
      'user'
      {
        if ([string]::IsNullOrEmpty($User))
          { throw "Supply the -User parameter or set GITHUB_USERNAME env variable "}
        GetUserPullRequests $User $State
      }
    }

  }
  catch
  {
    Write-Error "An unexpected error occurred $($Error[0])"
  }
}

function Get-GitHubTeams
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]
    $Organization = $Env:GITHUB_ORG
  )

  if ([string]::IsNullOrEmpty($Organization))
    { throw "An organization must be supplied"}

  try
  {
    $token = "?access_token=${Env:\GITHUB_OAUTH_TOKEN}"
    $uri = "https://api.github.com/orgs/$Organization/teams$token"
    $teamIds = Invoke-RestMethod -Uri $uri
    #Write-Verbose $global:GITHUB_API_OUTPUT

    $global:GITHUB_API_OUTPUT = @()
    $teamIds |
      % {
        $teamUri = "https://api.github.com/teams/$($_.id)$token";
        $membersUri = "https://api.github.com/teams/$($_.id)/members$token";
        $results = @{
          Team = Invoke-RestMethod -Uri $teamUri;
          Members = Invoke-RestMethod -Uri $membersUri;
        }

        $global:GITHUB_API_OUTPUT += $results

        $t = $results.Team
        Write-Host "`n[$($t.id)] $($t.name) - $($t.permission) - $($t.repos_count) repos"
        $results.Members | % { Write-Host "`t$($_.login)" }
      }
  }
  catch
  {
    Write-Error "An unexpected error occurred $($Error[0])"
  }
}

function New-GitHubRepository
{
  [CmdletBinding(DefaultParameterSetName='user')]
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]
    $Name,

    [Parameter(Mandatory = $false, ParameterSetName='org')]
    [switch]
    $ForOrganization,

    [Parameter(Mandatory = $false, ParameterSetName='org')]
    [string]
    $Organization = $Env:GITHUB_ORG,

    [Parameter(Mandatory = $false)]
    [string]
    $Description = '',

    [Parameter(Mandatory = $false)]
    [string]
    [ValidatePattern('^$|^http(s)?\:\/\/.*$')]
    $Homepage = '',

    [Parameter(Mandatory = $false)]
    [switch]
    $Private,

    [Parameter(Mandatory = $false)]
    [switch]
    $NoIssues,

    [Parameter(Mandatory = $false)]
    [switch]
    $NoWiki,

    [Parameter(Mandatory = $false)]
    [switch]
    $NoDownloads,

    [Parameter(Mandatory = $false, ParameterSetName='org')]
    [int]
    $TeamId,

    [Parameter(Mandatory = $false)]
    [switch]
    $AutoInit,

    # https://github.com/github/gitignore
    [Parameter(Mandatory = $false)]
    [string]
    $GitIgnoreTemplate,

    [Parameter(Mandatory = $false)]
    [switch]
    $NoClone
  )

  $token = "?access_token=${Env:\GITHUB_OAUTH_TOKEN}"

  $postData = @{
    name = $Name;
    description = $Description;
    homepage = $Homepage;
    private = $Private.ToBool();
    has_issues = !$NoIssues.ToBool();
    has_wiki = !$NoWiki.ToBool();
    has_downloads = !$NoDownloads.ToBool();
    auto_init = $AutoInit.ToBool();
    gitignore_template = $GitIgnoreTemplate;
  }

  if (![string]::IsNullOrEmpty($GitIgnoreTemplate) -and !$AutoInit.ToBool())
  {
    throw "To use a .gitignore, the -AutoInit switch must be specified"
  }

  switch ($PsCmdlet.ParameterSetName)
  {
    'org'
    {
      if ([string]::IsNullOrEmpty($Organization))
        { throw "An organization must be supplied"}

      if ($TeamId -eq $null)
        { throw "An organization repository must have a specified team id"}

      $postData.team_id = $TeamId;

      $uri = "https://api.github.com/orgs/$Organization/repos$token"
    }
    'user'
    {
      $uri = "https://api.github.com/user/repos$token"
    }
  }

  try
  {
    $params = @{
      Uri = $uri;
      Method = 'POST';
      ContentType = 'application/json';
      Body = (ConvertTo-Json $postData -Compress)
    }

    Write-Verbose $params.Body

    $repo = Invoke-RestMethod @params
    $global:GITHUB_API_OUTPUT = $repo
    #Write-Verbose $global:GITHUB_API_OUTPUT

    Write-Host "$($repo.full_name) Created at $($repo.clone_url)"

    if (!($NoClone.ToBool()))
      { git clone $repo.clone_url }
  }
  catch
  {
    Write-Error "An unexpected error occurred $($Error[0])"
  }
}

function New-GitHubFork
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]
    $Owner,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]
    $Repository,

    [Parameter(Mandatory = $false)]
    [switch]
    $ForOrganization,

    [Parameter(Mandatory = $false)]
    [string]
    $Organization,

    [Parameter(Mandatory = $false)]
    [switch]
    $NoClone
  )

  if (!$NoClone -and (Test-Path $Repository))
  {
    throw "Local directory $Repository already exists - change your cwd!"
  }

  if ($ForOrganization -and [string]::IsNullOrEmpty($Organization))
  {
    if ([string]::IsNullOrEmpty($Env:GITHUB_ORG))
    {
      throw ("When using -ForOrganization, -Organization must be specified or" +
      " GITHUB_ORG must be set in the environment")
    }
    $Organization = $Env:GITHUB_ORG
  }

  try
  {
    $token = "?access_token=${Env:\GITHUB_OAUTH_TOKEN}"
    $params = @{
      Uri = "https://api.github.com/repos/$Owner/$Repository/forks$token";
      Method = 'POST';
      ContentType = 'application/json';
    }

    if (![string]::IsNullOrEmpty($Organization))
      { $params.Uri += "&org=$Organization" }

    $fork = Invoke-RestMethod @params
    $global:GITHUB_API_OUTPUT = $fork
    #Write-Verbose $global:GITHUB_API_OUTPUT

    Write-Host "$($fork.full_name) forked from $Owner/$Repository to ($($fork.clone_url))"

    # forks are async, so clone the original repo, then tweak our remotes
    if (!$NoClone)
    {
      $sourceRepo = "https://github.com/$Owner/$Repository.git"
      git clone $sourceRepo
      Push-Location $Repository
      Write-Host "Resetting origin to $($fork.clone_url)"
      git remote set-url origin $fork.clone_url
      Write-Host "Adding origin as $sourceRepo"
      git remote add upstream $sourceRepo
      Pop-Location
    }
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
  Get-GitHubPullRequests, Set-GitHubUserName, Set-GitHubOrganization,
  Get-GitHubTeams, New-GitHubRepository, New-GitHubFork
