# Posh-GitHub

Powershell cmdlets that expose the GitHub API

## Early Code

This is a super super early take on some rudimentary GitHub functionality.
I will continue to improve this over time as need grows / time allows.

## Compatibility

* This is written for Powershell v2 / .NET4 at the moment.  It should work just
fine under PowerShell v3.  Yes, I know that instead of using WebClient, I could
have used [Invoke-RestMethod][invoke-rest] (and might in the future)

* This is written against GitHub API v3

[invoke-rest]: http://technet.microsoft.com/en-us/library/hh849971.aspx

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

### Automatic via PsGet

It seems like it would make sense to distribute this through [PsGet][PsGet].
First things first though ;0

[PsGet]:http://psget.net/

## Support Commands

### New-GitHubOAuthToken

Used to create a new OAuth token for use with the GitHub using your
username/password in basic auth over HTTPS.  The result is stashed in the
`GITHUB_OAUTH_TOKEN` environment variable.

```powershell
New-GitHubOAuthToken -UserName Bob -Password bobpassword
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

## Roadmap

None really.. just waiting to see what I might need.

