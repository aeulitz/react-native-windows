<#
.SYNOPSIS
Helper script to download and setup of packages to re-create the Office build environment for
react-native-win32.dll.

.PARAMETER Action
Specifies the action the script should perform. Valid values are 'install' and 'uninstall'. Both
actions are governed by the information in the configuration file (see 'Configuration' parameter).
An 'uninstall' needs to be run with the same configuration to undo the effects of a previous
'install'.

.PARAMETER Configuration
Path name of a JSON file containing information about the Office build environment packages.
Optional. If omitted, the script attempts to use a co-located 'SetupOfficeBuild.json' file.

.DESCRIPTION
A successful install will create an '_OfficeBuild.ps1' script that, when invoked, attempts to build
react-native-win32.dll using the Office compiler and standard and SDK headers and libs. A regular
build ("msbuild ReactWindows-Desktop.sln ...") should remain unaffected.
#>
param (
	[ValidateSet('install', 'uninstall')]
	[string] $Action = 'install',
	[string] $Configuration = "",
	[object[]] $FeedCredentials = $null,
	[switch] $UseNugetExe = $false,
	[string] $NugetExe = "nuget"
)

<#
.SYNOPSIS
Converts JSON custom object into writeable PS hash.

.PARAMETER obj
Custom object returned from ConvertFrom-Json cmdlet.

.OUTPUTS
Writeable PS hash.

.DESCRIPTION
JSON file content obtained via the ConvertFrom-Json cmdlet is a read-only custom object. This
function turns it into a regular PS hash table so that the data can be annotated with additional
properties.
#>
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

#region Globals and command-line args

$ScriptName = (Get-Item $PSCommandPath).BaseName
$ProjectRootDir = Get-Item "$PSScriptRoot\.."

if ([string]::IsNullOrEmpty($Configuration)) {
	$Configuration = $PSCommandPath.Substring(0, $PSCommandPath.LastIndexOf('.')) + '.json'
}

$ConfigData = ConvertFromPSCustomObject (Get-Content $Configuration | ConvertFrom-Json)
if ($ConfigData.packageTargetDirectory -eq $null) {
	$ConfigData.packageTargetDirectory = "$ProjectRootDir\packages"
}

if (!$UseNuget -and ($FeedCredentials -ne $null)) {
	foreach ($feedCredential in $FeedCredentials) {
		$feed, $pat = $feedCredential
		$ConfigData.feeds[$feed].pat = $pat
	}
}

# '_' prefix is meant to indicate transient files that are not meant to be committed

$BuildPropsFileName = "$ProjectRootDir\_OfficeBuild.props"
$BuildTargetsFileName = "$ProjectRootDir\_OfficeBuild.targets"
$BuildScriptFileName = "$ProjectRootDir\_OfficeBuild.ps1"

#endregion

#region NuGet helpers

function EmitPackageConfig($Packages) {
	$packageConfigFile = "$($env:TEMP)\packages.config"
	if (Test-Path $packageConfigFile) { Remove-Item $packageConfigFile }

@"
<?xml version="1.0" encoding="utf-8"?>
<packages>
$(
	foreach ($k in $Packages.Keys) {
		"  <package id=`"$($Packages[$k].name)`" version=`"$($Packages[$k].requestedVersion)`" />`n"
	}
)
</packages>
"@ | Out-File -FilePath $packageConfigFile -Encoding ascii

	return $packageConfigFile
}

function InstallNugetPackage(
	[string] $Name,
	[string] $Version,
	[string] $Feed,
	$Credential,
	$TargetDir = $ConfigData.packageTargetDirectory) {

	$pkg = GetLocallyInstalledNugetPackage -Name $Name -Version $Version -Destination $TargetDir
	if ($pkg -ne $null) { return $pkg }

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

#endregion

function Install() {
	if ($UseNugetExe) {

		$packageConfigFile = EmitPackageConfig $ConfigData.packages
		try {
			& $NugetExe install $packageConfigFile -OutputDirectory $ConfigData.packageTargetDirectory
		}
		finally {
			Remove-Item $packageConfigFile
		}

		foreach($key in $ConfigData.packages.Keys) {
			$packageInfo = $ConfigData.packages[$key]
			$package = Get-Package -Name $packageInfo.name -AllVersions -Destination $ConfigData.packageTargetDirectory -ErrorAction SilentlyContinue

			if ($package -eq $null) {
				throw "failed to install `"$($packageInfo.name)`" package"
			} elseif ($package -is [array]) {
				throw "multiple `"$($packageInfo.name)`" packages"
			}

			$packageInfo.package = $package
			$packageInfo.directory = GetNugetPackageInstallDir $package
		}
	} else {

		RegisterFeeds
		try {
			foreach ($packageKey in $ConfigData.packages.Keys) {
				$pi = $ConfigData.packages[$packageKey]

				Write-Host "Installing package $($pi.name) $($pi.version) ... " -NoNewline
				$pi.package = InstallNugetPackage -Name $pi.name -Version $pi.version -Feed $pi.feed -Credential $ConfigData.feeds[$pi.feed].credential
				$pi.directory = GetNugetPackageInstallDir $pi.package
				Write-Host "done."
			}
		} finally {
			UnregisterFeeds
		}
	}

	FixUpHeaders $ConfigData.packages
	EmitBuildPropsFile $ConfigData.packages
	EmitBuildTargetsFile $ConfigData.packages
	EmitOfficeBuildScript
}

function Uninstall() {
	foreach ($packageKey in $ConfigData.packages.Keys) {
		$pi = $ConfigData.packages[$packageKey]
		Write-Host "Uninstalling package $($pi.name) $($pi.version) ... " -NoNewline
		UninstallNugetPackage -Name $pi.name -Version $pi.version
		Write-Host "done."
	}

	if (Test-Path $BuildPropsFileName) { Remove-Item $BuildPropsFileName }
	if (Test-Path $BuildTargetsFileName) { Remove-Item $BuildTargetsFileName }
	if (Test-Path $BuildScriptFileName) { Remove-Item $BuildScriptFileName }
}

function FixUpHeaders($Packages) {
	# Super-impose headers from Microsoft.VCCompiler.Headers.Office onto
	# VisualCppTools.InternalAddCHPE.VS2017Layout.
	#
	# Thomas Wise: "The only parts you likely need are the headers under lib/native/atlmfc/include and
	# lib/native/include. You will [need] to replace those files in the visualcpptools package with the ones in
	# Microsoft.vccompiler.headers.office package. Any that are only in visualcpptools should be
	# included in the combined packages."
	# Andreas Eulitz: "so essentially 'copy /y headers-office-folder/*  visualcpptools-folders '?"
	# Thomas Wise: "For each of the two folders, yes"
	Copy-Item -Recurse -Force -Path "$($Packages['CompilerHeaders'].directory)\lib\native\atlmfc\include\*" -Destination "$($Packages['Compiler'].directory)\lib\native\atlmfc\include"
	Copy-Item -Recurse -Force -Path "$($Packages['CompilerHeaders'].directory)\lib\native\include\*" -Destination "$($Packages['Compiler'].directory)\lib\native\include"
}

function EmitBuildPropsFile($Packages) {
	if (Test-Path $BuildPropsFileName) { Remove-Item $BuildPropsFileName }

@"
<?xml version="1.0" encoding="utf-8"?>

<!-- This file was generated by the '$ScriptName' script. -->

<Project ToolsVersion="14.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
	<PropertyGroup>
		<VC_VC_IncludePath>$($Packages['Compiler'].directory)\lib\native\include</VC_VC_IncludePath>
		<VC_ATLMFC_IncludePath>$($Packages['Compiler'].directory)\lib\native\atlmfc\include</VC_ATLMFC_IncludePath>
		<UniversalCRT_IncludePath>$($Packages['SDKHeaders'].directory)\inc\ucrt</UniversalCRT_IncludePath>
		<UM_IncludePath>$($Packages['SDKHeaders'].directory)\inc\coresdk</UM_IncludePath>
		<KIT_SHARED_IncludePath>$($Packages['SDKHeaders'].directory)\inc\coresdk</KIT_SHARED_IncludePath>
		<WinRT_IncludePath>$($Packages['SDKHeaders'].directory)\inc\rt</WinRT_IncludePath>
		<CppWinRT_IncludePath>$($Packages['SDKHeaders'].directory)\inc\cppwinrt</CppWinRT_IncludePath>
		<DotNetSdk_IncludePath>$($Packages['SDKHeaders'].directory)\inc\coresdk</DotNetSdk_IncludePath>
	</PropertyGroup>
</Project>
"@ | Out-File -FilePath $BuildPropsFileName -Encoding ascii
}

function EmitBuildTargetsFile($Packages) {
	if (Test-Path $BuildTargetsFileName) { Remove-Item $BuildTargetsFileName }

	# It might seem unusual to set properties in a *.targets file, but - even if additive -
	# $ExecutablePath assignments in the respective *.props file preclude assignments to the same
	# property by the rest of the build system (i.e. the build system appears to make $ExecutablePath
	# assignments only if the property is unset).

@"
<?xml version="1.0" encoding="utf-8"?>

<!-- This file was generated by the '$ScriptName' script. -->

<Project ToolsVersion="14.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
	<PropertyGroup>
		<HostArchitecture Condition="'`$(PROCESSOR_ARCHITECTURE)' == 'AMD64' Or '`$(PROCESSOR_ARCHITEW6432)' == 'AMD64'">Hostx64</HostArchitecture>
		<HostArchitecture Condition="'`$(PROCESSOR_ARCHITECTURE)' != 'AMD64' And '`$(PROCESSOR_ARCHITEW6432)' != 'AMD64'">Hostx86</HostArchitecture>

		<TargetArchitecture Condition="'`$(Platform)' == 'arm'">arm</TargetArchitecture>
		<TargetArchitecture Condition="'`$(Platform)' == 'arm64'">arm64</TargetArchitecture>
		<TargetArchitecture Condition="'`$(Platform)' == 'chpe'">chpe</TargetArchitecture>
		<TargetArchitecture Condition="'`$(Platform)' == 'x64'">x64</TargetArchitecture>
		<TargetArchitecture Condition="'`$(Platform)' == 'x86' Or '`$(Platform)' == 'Win32'">x86</TargetArchitecture>

		<ExecutablePath>$($Packages['Compiler'].directory)\lib\native\bin\`$(HostArchitecture)\`$(TargetArchitecture);`$(ExecutablePath)</ExecutablePath>
		<LibraryPath>$($Packages['Compiler'].directory)\lib\native\lib\`$(TargetArchitecture);$($Packages['SDKBin'].directory)\lib\`$(TargetArchitecture);`$(LibraryPath)</LibraryPath>
	</PropertyGroup>

	<ItemDefinitionGroup>
		<ClCompile>
			<PreprocessorDefinitions>OFFICEDEV_DONT_POLLUTE_WINDOWS;%(PreprocessorDefinitions)</PreprocessorDefinitions>
		</ClCompile>
	</ItemDefinitionGroup>
</Project>
"@ | Out-File -FilePath $BuildTargetsFileName -Encoding ascii
}

function EmitOfficeBuildScript() {

	if (Test-Path $BuildScriptFileName) { Remove-Item $BuildScriptFileName }
@"
# This file was generated by the '$ScriptName' script.
param(
	[string] `$Platform = 'x64',
	[string] `$Configuration = 'debug',
	`$Solution = `$null)

if (`$Solution -eq `$null) {
	`$Solution = "`$PSScriptRoot\ReactWindows-Desktop.sln"
}

msbuild /p:Platform=`$Platform /p:Configuration=`$Configuration /p:RNWBuildOverrideProps='$BuildPropsFileName' /p:RNWBuildOverrideTargets='$BuildTargetsFileName' /p:NoCppWinRT=true `$Solution @args
"@ | Out-File -FilePath $BuildScriptFileName -Encoding ascii
}

switch ($Action) {
	'install' { Install }
	'uninstall' { Uninstall }
	default { throw "unexpected action $Action" }
}
