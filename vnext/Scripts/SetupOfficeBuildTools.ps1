<#
.SYNOPSIS
Helper script to automate downloading and setup of packages to re-create the Office environment for
building React Native for Windows.

#>

# can we emit a "wrapper" .vcxproj that includes to the original rnw.vcxproj?


param (
	[ValidateSet('install', 'uninstall')]
	$Action = 'install',
	# $NugetExe = $env:NUGET_EXE, # TODO: replace with package mgmt cmdlets
	$Configuration = $null
)

function ConvertFromPSCustomObject($obj) {
	if ($obj -is [System.Management.Automation.PSCustomObject]) {
		$hash = @{}
		foreach ($np in ($obj | Get-Member -MemberType NoteProperty)) {
			$hash[$np.Name] = (ConvertFromPSCustomObject $obj."$($np.Name)")
		}
		return $hash
	} else {
		return $obj
	}
}

#region Globals

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRootDir = Get-Item "$ScriptDir\.."

#if ($NugetExe -eq $null) { throw "need to specify NuGet executable" }
#if (!(Test-Path $NugetExe)) { throw "can't find `"$NugetExe`"" }
#if ($NugetTargetDir -eq $null) { $NugetTargetDir = "$ProjectRootDir\packages" }

if ($Configuration -eq $null) {
	$Configuration = $MyInvocation.MyCommand.Path.Substring(0, $MyInvocation.MyCommand.Path.LastIndexOf('.')) + '.json'
}

$ConfigData = ConvertFromPSCustomObject (Get-Content $Configuration | ConvertFrom-Json)
if ($ConfigData.packageTargetDirectory -eq $null) {
	$ConfigData.packageTargetDirectory = "$ProjectRootDir\packages"
}

#endregion

function InstallNugetPackage(
	[string] $Name,
	[string] $Version,
	[string] $Feed,
	$Credential,
	$TargetDir = $ConfigData.packageTargetDirectory) {

	$pkg = GetLocallyInstalledNugetPackage -Name $Name -Version $Version -Destination $TargetDir
	if ($pkg -ne $null) { return $pkg }

	# &$NugetExe install $Name -OutputDirectory $NugetTargetDir -Source $OfficeNugetFeed
	Install-Package -Name $Name -RequiredVersion $Version -Source $Feed -Credential $Credential -Destination $TargetDir | Out-Null

	return (GetLocallyInstalledNugetPackage -Name $Name -Version $Version -Destination $TargetDir)
}

function UninstallNugetPackage(
	[string] $Name,
	[string] $Version,
	[string] $TargetDir = $ConfigData.packageTargetDirectory) {
	$pkg = GetLocallyInstalledNugetPackage -Name $Name -Version $Version -Destination $TargetDir
	if ($pkg -eq $null) { return }
	Uninstall-Package -Name $Name -RequiredVersion $Version -Destination $TargetDir | Out-Null
}

function GetLocallyInstalledNugetPackage(
	[string] $Name,
	[string] $Version,
	[string] $TargetDir = $ConfigData.packageTargetDirectory) {
	return (Get-Package -Name $Name -RequiredVersion $Version -Destination $TargetDir -ErrorAction SilentlyContinue)
}

function GetNugetPackageInstallDir($Package) {
	return (Split-Path -Parent $Package.Source)
}

function RegisterFeeds() {
	# TODO: detect if feed is already registered

	foreach ($feedName in $ConfigData.feeds.Keys) {
		$pat = ConvertTo-SecureString $ConfigData.feeds[$feedName].pat -AsPlainText -Force
		$cred = New-Object System.Management.Automation.PSCredential <# username, irrelevant, but cannot be empty #> "ado", $pat
		Register-PackageSource -Name $feedName -Location $ConfigData.feeds[$feedName].url -ProviderName NuGet -Credential $cred <# needed to avoid prompts when installing packages from this sources #> -Trusted | Out-Null
		$ConfigData.feeds[$feedName].credential = $cred
	}
}

function UnregisterFeeds() {
	foreach ($feedName in $ConfigData.feeds.Keys) {
		Unregister-PackageSource -Source $feedName -ProviderName NuGet # does this require passing credentials?
	}
}

function Install() {
	RegisterFeeds
	try {
		$officeCompilerPackage = $null
		$officeHeadersPackage = $null

		foreach ($packageName in $ConfigData.packages.Keys) {
			$pi = $ConfigData.packages[$packageName]

			Write-Host "Installing package $packageName $($pi.version) ... " -NoNewline
			$package = InstallNugetPackage -Name $packageName -Version $pi.version -Feed $pi.feed -Credential $ConfigData.feeds[$pi.feed].credential
			Write-Host "done."

			switch ($packageName) {
				"Microsoft.VCCompiler.Headers.Office" { $officeHeadersPackage = $package }
				"VisualCppTools.InternalAddCHPE.VS2017Layout" {$officeCompilerPackage = $package }
			}
		}

		# Super-impose headers from Microsoft.VCCompiler.Headers.Office onto
		# VisualCppTools.InternalAddCHPE.VS2017Layout.
		#
		# Thomas Wise: "The only parts you likely need are the headers under lib/native/atlmfc/include and
		# lib/native/include. You will to replace those files in the visualcpptools package with the ones in
		# Microsoft.vccomplier.headers.office package. Any that are only in visualcpptools should be
		# included in the combined packages."
		# Andreas Eulitz: "so essentially 'copy /y headers-office-folder/*  visualcpptools-folders '?"
		# Thomas Wise: "For each of the two folders, yes"

		Copy-Item -Recurse -Force -Path "$(GetNugetPackageInstallDir $officeHeadersPackage)\lib\native\atlmfc\include\*" -Destination "$(GetNugetPackageInstallDir $officeCompilerPackage)\lib\native\atlmfc\include"
		Copy-Item -Recurse -Force -Path "$(GetNugetPackageInstallDir $officeHeadersPackage)\lib\native\include\*" -Destination "$(GetNugetPackageInstallDir $officeCompilerPackage)\lib\native\include"
	} finally {
		UnregisterFeeds
	}
}

function Uninstall() {
	foreach ($packageName in $ConfigData.packages.Keys) {
		$pi = $ConfigData.packages[$packageName]
		Write-Host "Uninstalling package $packageName $($pi.version) ... " -NoNewline
		UninstallNugetPackage -Name $packageName -Version $ConfigData.packages[$packageName].version
		Write-Host "done."
	}
}

switch ($Action) {
	'install' { Install }
	'uninstall' { Uninstall }
	default { throw "unexpected action $Action" }
}
