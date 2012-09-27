# Posh-GitHub

Powershell cmdlets that expose the GitHub API

## Early Code

This is a super super early take on some rudimentary GitHub functionality.
I will continue to improve this over time as need grows / time allows.  There
may be bugs or things I haven't thought of -- please report if that's the case!

## Compatibility

* This is written for Powershell v3 and makes use of the simplified
[Invoke-RestMethod][invoke-rest] instead of the `WebClient` class.
  * Powershell v3 can be installed with [Chocolatey][Choc] via `cinst powershell`

* This is written against GitHub API v3

[invoke-rest]: http://technet.microsoft.com/en-us/library/hh849971.aspx
[Choc]: http://www.chocolatey.org

## Installation

### Manual for Now

Git clone this to your user modules directory

```powershell
#Find appropriate module directory for user
$modulePath = $Env:PSModulePath -split ';' |
  ? { $_.StartsWith($Env:USERPROFILE) } |
  Select -First 1
$poshGitHub = Join-Path $modulePath 'posh-github'

git clone https://github.com/Iristyle/Posh-GitHub $poshGitHub

#add the call to Import-Module to user profile
$profilePath = Join-Path (Split-Path $modulePath) `
  'Microsoft.PowerShell_profile.ps1'

'Import-Module Posh-Github' |
  Out-File -FilePath $profilePath -Append -Encoding UTF8
```

#### Updating

```powershell
Update-PoshGitHub
```

This is a real simple mechanism for now -- it finds where the module is
installed, it does a `git pull` to refresh the code, unloads the module and
then reloads it.

In the future, this will be handled by a package manager, but for now it works.

Note that it uses the path of the currently loaded Posh-GitHub module to
determine which physical Powershell module to update.  As long as the currently
loaded module is the one installed to your profile, this will work fine.

### Automatic via PsGet

It seems like it would make sense to distribute this through [PsGet][PsGet].
First things first though ;0

[PsGet]:http://psget.net/

## Supported Commands

### Environment Variables

Cmdlets are set to use the following environment variables as defaults

* `GITHUB_OAUTH_TOKEN` - Required for all cmdlets - use `New-GitHubOAuthToken`
  to establish one
* `GITHUB_USERNAME` - Can be optionally set to specify a global default user

### Last Command Output

A Powershell object created from the incoming JSON is always stored
in the variable `$GITHUB_API_OUTPUT` after each call to the GitHub API

### New-GitHubOAuthToken

Used to create a new OAuth token for use with the GitHub using your
username/password in basic auth over HTTPS.  The result is stashed in the
`GITHUB_OAUTH_TOKEN` environment variable.

```powershell
New-GitHubOAuthToken -UserName Bob -Password bobpassword
```

```powershell
New-GitHubOAuthToken -UserName Bob -Password bobpassword -NoEnvironmentVariable
```

### Set-GitHubUserName

Adds the username to the current Powershell session and sets a global User
environment variable

```powershell
Set-GitHubUserName Iristyle
```

### Get-GitHubRepositories

List all your repositories - gives a fork indicator, a date for when the last
update (push) occurred, how many open issues and size

```powershell
Get-GitHubRepositories
```

```powershell
Get-GitHubRepositories -Type owner -Sort pushed
```

### Get-GitHubIssues

Will get a list of issue number / title for a given repo owner

Must be ordered by Owner, Repo if not using switches on params

```powershell
Get-GitHubIssues EastPoint Burden
```

Switch on params form

```powershell
Get-GitHubIssues -Owner EastPoint -Repository Burden
```

Closed issues

```powershell
Get-GitHubIssues -Owner EastPoint -Repository Burden -State closed
```

### New-GitHubPullRequest

Initiates a new pull request to the `upstream` repo.

If you follow the convention of setting a remote named upstream, and you create
new branches for new work, then this cmdlet should work mostly automatically
to find the appropriate owner and repo to send the pull request to, and it will
base it on the origin username and current branch name.

Supports a title and body.

```powershell
New-GitHubPullRequest -Title 'Fixed some stuff' -Body 'More detail'
```

Support an issue id.

```powershell
New-GitHubPullRequest -Issue 5
```

Supports a branch other than master to send the pull to.

```powershell
New-GitHubPullRequest -Issue 10 -Base 'devel'
```

If you don't have a remote set, then override the default sniffing behavior.

```powershell
New-GitHubPullRequest -Issue 10 -Owner EastPoint -Repository Burden
```

If you're not on the current branch you want to send the pull for, override it.

```powershell
New-GitHubPullRequest -Title 'fixes' -Head 'myusername:somebranch'
```

Note that GitHub generally requires that head be prefixed with `username:`

## Get-GitHubEvents

Will list, in chronological order, the last 30 events that you have generated

```powershell
Get-GitHubEvents
```

Will list the public events for another user

```powershell
Get-GitHubEvents -User Iristyle
```

## Roadmap

None really.. just waiting to see what I might need.

