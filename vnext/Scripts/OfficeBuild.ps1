<#
.SYNOPSIS
Helper script to automate the setup of Office build tool packages, and the build of
react-native-win32.dll with these tools.

.PARAMETER Action
Specifies the action the script should perform. Valid values are 'install', 'uninstall' and 'build'.
The 'install' and 'uninstall' actions are governed by the information in the configuration file
(see 'Configuration' parameter).

.PARAMETER BuildPlatform
Target platform for 'build' action. Defaults to 'x64'.

.PARAMETER BuildConfiguration
Target configuration for 'build' action. Defaults to 'Debug'.

.PARAMETER Configuration
Path name of a JSON file containing information about the Office build environment packages.
Optional. If omitted, the script attempts to use a co-located 'OfficeBuild.json' file.

.PARAMETER FeedCredentials
List of pairs where the first pair item is a feed name (as specified in the configuration file) and
the second pair item a credential object for the respective feed. Optional; unused when installing
via nuget.exe (see 'UseNuget' parameter).

.PARAMETER UseNuget
If specified, the script installs via nuget.exe (otherwise, it installs via the PowerShell package
management cmdlets). See 'NugetCmd' parameter for nuget.exe locations.

.PARAMETER NugetCmd
Path (including file name) of nuget.exe. If unspecified, "nuget" is expected to be found among the
executable paths.

.PARAMETER ADOLog
Optimizes log output for ADO build pipelines.

.PARAMETER BuildSolution
Solution (.sln) for 'build' action. Defaults to 'ReactWindows-Desktop.sln'.

.DESCRIPTION
This script is intended to improve binary compatibility of react-native-win32.dll and Office
executables by building with the same headers and libraries while using the same compiler and
linker. The intended workflow consists of several script invocations:
- OfficeBuild install
- OfficeBuild build [<platform1>] [<configuration1>]
- OfficeBuild build [<platform2>] [<configuration1>]
- OfficeBuild build ...
- OfficeBuild uninstall

As the 'install' action is idempotent and the 'build' action implies 'install', the explicit
'install' call can be omitted.
#>
param (
	[ValidateSet('install', 'uninstall', 'build', '_verifybuild')]
	[string] $Action = 'install',

	[ValidateSet('x64', 'x86')]
	[string] $BuildPlatform = "x64",

	[ValidateSet('Release', 'Debug')]
	[string] $BuildConfiguration = "Debug",

	[string] $PackageTargetDirectory = $null,

	[string] $Configuration = "",
	[object[]] $FeedCredentials = $null,
	[switch] $UseNuget = $true,
	[string] $NugetCmd = "nuget", # default value assumes nuget.exe is on the path

	[switch] $ADOLog = $false,

	[string] $MSBuildCmd = "msbuild", # default value assumes msbuild.exe is on the path

	[string] $BuildSolution = "",
	[string] $APIKey
)

#region Globals and Command-Line Argument Helper Methods

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

function RemoveIfPresent($FileName) {
	if (Test-Path $FileName) { Remove-Item $FileName }
}

#endregion

#region Globals and Command-Line Arguments

$ScriptName = (Get-Item $PSCommandPath).BaseName
$ProjectRootDir = Get-Item "$PSScriptRoot\.."

if (!$ADOLog) {
	$LogFile = "$env:TEMP\ReactNativeWindows-$ScriptName.log"
	RemoveIfPresent $LogFile
}

$ErrorCount = 0
$WarningCount = 0

if ([string]::IsNullOrEmpty($Configuration)) {
	$Configuration = $PSCommandPath.Substring(0, $PSCommandPath.LastIndexOf('.')) + '.json'
}

$ScriptConfigurationData = ConvertFromPSCustomObject (Get-Content $Configuration | ConvertFrom-Json)

if ([string]::IsNullOrEmpty($PackageTargetDirectory)) {
	if ($ScriptConfigurationData.packageTargetDirectory -ne $null) {
		$PackageTargetDirectory = $ScriptConfigurationData.packageTargetDirectory
	} else {
		$PackageTargetDirectory = "$ProjectRootDir\packages"
	}
}

if (!(Test-Path $PackageTargetDirectory)) { [void](mkdir $PackageTargetDirectory) }

if (!$UseNuget -and ($FeedCredentials -ne $null)) {
	foreach ($feedCredential in $FeedCredentials) {
		$feed, $pat = $feedCredential
		$ScriptConfigurationData.feeds[$feed].pat = $pat
	}
}

if ([string]::IsNullOrEmpty($BuildSolution)) {
	$BuildSolution = "$ProjectRootDir\ReactWindows-Desktop.sln"
}

#endregion

#region Low-Level Helpers

function NullCoalesce($a, $b) {
	if ($a -ne $null) { $a } else { $b }
}

function Assert ($condition, $message = $null) {
	if (!$condition) { throw (NullCoalesce $message "assertion failed") }
}

#region NuGet Helpers

function CreatePackageConfig($Packages, $PackageConfigFile) {
@"
<?xml version="1.0" encoding="utf-8"?>
<packages>
$(
	foreach ($k in $Packages.Keys) {
		"  <package id=`"$($Packages[$k].name)`" version=`"$($Packages[$k].version)`" />`n"
	}
)
</packages>
"@ | Out-File -FilePath $PackageConfigFile -Encoding ascii

	LogComment "created NuGet package configuration file `"$PackageConfigFile`""
}

function InstallNugetPackage(
	[string] $Name,
	[string] $Version,
	[string] $Feed,
	$Credential,
	$TargetDir = $PackageTargetDirectory) {

	$pkg = GetLocallyInstalledNugetPackage -Name $Name -Version $Version -Destination $TargetDir
	if ($pkg -ne $null) { return $pkg }

	Install-Package -Name $Name -RequiredVersion $Version -Source $Feed -Credential $Credential -Destination $TargetDir | Out-Null
	LogComment "installed package $Name $Version"
}

function UninstallNugetPackage(
	[string] $Name,
	[string] $Version,
	[string] $TargetDir = $PackageTargetDirectory) {
	$pkg = GetLocallyInstalledNugetPackage -Name $Name -Version $Version -Destination $TargetDir
	if ($pkg -eq $null) { return }
	Uninstall-Package -Name $Name -RequiredVersion $Version -Destination $TargetDir | Out-Null
	LogComment "uninstalled package $Name $Version"
}

function GetLocallyInstalledNugetPackage(
	[string] $Name,
	[string] $Version,
	[string] $TargetDir = $PackageTargetDirectory) {
	return (Get-Package -Name $Name -RequiredVersion $Version -Destination $TargetDir -ErrorAction SilentlyContinue)
}

function GetNugetPackageInstallDir($Package) {
	return (Split-Path -Parent $Package.Source)
}

function RegisterFeeds() {
	# TODO: detect if feed is already registered

	foreach ($feedName in $ScriptConfigurationData.feeds.Keys) {
		$pat = ConvertTo-SecureString $ScriptConfigurationData.feeds[$feedName].pat -AsPlainText -Force
		$cred = New-Object System.Management.Automation.PSCredential <# username, irrelevant, but cannot be empty #> "ado", $pat
		Register-PackageSource -Name $feedName -Location $ScriptConfigurationData.feeds[$feedName].url -ProviderName NuGet -Credential $cred <# needed to avoid prompts when installing packages from this sources #> -Trusted | Out-Null
		$ScriptConfigurationData.feeds[$feedName].credential = $cred
	}
}

function UnregisterFeeds() {
	foreach ($feedName in $ScriptConfigurationData.feeds.Keys) {
		Unregister-PackageSource -Source $feedName -ProviderName NuGet # does this require passing credentials?
	}
}
#endregion

#region Log Helpers

enum LogMessageType { Comment; Warning; Error; File}

[System.Collections.Stack] $LogDeferrals = [System.Collections.Stack]::new()

function PushLogDeferral() {
	$LogDeferrals.Push([System.Collections.ArrayList]::new())
}

function PopLogDeferral() {
	$list = $LogDeferrals.Pop()
	if ($LogDeferrals.Count -gt 0) {
		[void] $LogDeferrals.Peek().AddRange($list)
	} else {
		foreach ($entry in $list) {
			switch ($entry.Type) {
				([LogMessageType]::File) { LogAppend $entry.FileName }
				default { Log $entry.Type $entry.Message }
			}
		}
	}
}

function Log([LogMessageType] $Type, [string] $Message) {
	if ($LogDeferrals.Count -gt 0) {
		[void] $LogDeferrals.Peek().Add(@{Type = $Type; Message = $Message})
	} else {
		switch ($Type) {
			([LogMessageType]::Comment) {
				if ($ADOLog) {
					# ADO prefixes message with time stamp
					Write-Host $Message
				} else {
					("{0,-14} COMMENT: {1}" -f (Get-Date).ToString("HH:mm:ss.FFFFF"), $Message) |
						Out-File -Append -Encoding ascii -FilePath $LogFile
				}
			}
			([LogMessageType]::Warning) {
				Write-Host -ForegroundColor Yellow "WARNING: $Message"

				if (!$ADOLog) {
					("{0,-14} WARNING: {1}" -f (Get-Date).ToString("HH:mm:ss.FFFFF"), $Message) |
						Out-File -Append -Encoding ascii -FilePath $LogFile
				}

				++$Script:WarningCount
			}
			([LogMessageType]::Error) {
				Write-Host -ForegroundColor Red "ERROR: $Message"

				if (!$ADOLog) {
					("{0,-14} ERROR: {1}" -f (Get-Date).ToString("HH:mm:ss.FFFFF"), $Message) |
						Out-File -Append -Encoding ascii -FilePath $LogFile
				}

				++$Script:ErrorCount
			}
		}
	}
}

function LogComment([string] $Message) { Log ([LogMessageType]::Comment) $Message }
function LogWarning([string] $Message) { Log ([LogMessageType]::Warning) $Message }
function LogError([string] $Message) { Log ([LogMessageType]::Error) $Message }

function LogAppend($fileName) {
	if ($LogDeferrals.Count -gt 0) {
		[void] $LogDeferrals.Peek().Add(@{Type = [LogMessageType]::File; FileName = $fileName})
	} else {

		if ($ADOLog) {
			Write-Host ((Get-Content $fileName) -join "`n")
		} else {
			Get-Content $fileName | Out-File -Append -Encoding ascii -FilePath $LogFile
		}
	}
}

#endregion

function GetInstalledPackages() {

	$installedPackages = @{}

	foreach ($key in $ScriptConfigurationData.packages.Keys) {
		$requestedPackage = $ScriptConfigurationData.packages[$key]
		$installedPackage = Get-Package -Name $requestedPackage.name -AllVersions -Destination $PackageTargetDirectory -ErrorAction SilentlyContinue

		if ($installedPackage -eq $null) {
			throw "could not find installed version of `"$($requestedPackage.name)`" package"
		} elseif ($installedPackage -is [array]) {
			throw "multiple versions of `"$($requestedPackage.name)`" packages are installed"
		}

		if ($requestedPackage.version -ne $installedPackage.Version) {
			LogWarning "requested $($requestedPackage.name) package version $($requestedPackage.version)), installed version $($installedPackage.Version)"
		}

		$installedPackages[$key] = $installedPackage
	}

	return $installedPackages
}

function FixUpHeaders($Packages) {
	$headerPackageDir = GetNugetPackageInstallDir $Packages['CompilerHeaders']

	$compilerPackageDir = GetNugetPackageInstallDir $Packages['Compiler']

	$sentinel = "$compilerPackageDir\$ScriptName-HeadersFixedUp.snt"

	if (Test-Path $sentinel) {
		# idempotence path
		return
	}

	Write-Host "Fixing headers ... " -NoNewline

	# Super-impose headers from Microsoft.VCCompiler.Headers.Office onto
	# VisualCppTools.InternalAddCHPE.VS2017Layout.
	#
	# Thomas Wise: "The only parts you likely need are the headers under lib/native/atlmfc/include and
	# lib/native/include. You will [need] to replace those files in the visualcpptools package with the ones in
	# Microsoft.vccompiler.headers.office package. Any that are only in visualcpptools should be
	# included in the combined packages."
	# Andreas Eulitz: "so essentially 'copy /y headers-office-folder/*  visualcpptools-folders '?"
	# Thomas Wise: "For each of the two folders, yes"
	Copy-Item -Recurse -Force -Path "$headerPackageDir\lib\native\atlmfc\include\*" -Destination "$compilerPackageDir\lib\native\atlmfc\include"
	Copy-Item -Recurse -Force -Path "$headerPackageDir\lib\native\include\*" -Destination "$compilerPackageDir\lib\native\include"

	New-Item $sentinel | Out-Null

	Write-Host "done."
}

function CreateExportDefinitionFile(
	[string] $SourceFileName,
	[string] $TargetFileName) {
	assert (Test-Path $SourceFileName), "`"$SourceFileName`" export definition file can't be found."
	Get-Content $SourceFileName | Where-Object {$_ -notmatch "WINRT_"} > $TargetFileName

	LogComment "created export definition file `"$TargetFileName`""
}

function CreateBuildPropsFile($BuildPropsFileName, $Packages) {
	$compilerPackageDir = GetNugetPackageInstallDir $Packages['Compiler']
	$sdkHeadersPackageDir = GetNugetPackageInstallDir $Packages['SDKHeaders']

@"
<?xml version="1.0" encoding="utf-8"?>

<!-- This file was generated by the '$ScriptName' script. -->

<Project ToolsVersion="14.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
	<PropertyGroup>
		<!--
		The property below prevents
			%ProgramFiles%\Microsoft Visual Studio\2017\Enterprise\Common7\IDE\VC\VCTargets\Microsoft.Cpp.Common.props
		from including 
			%ProgramFiles%\Windows Kits\10\DesignTime\CommonConfiguration\Neutral\uCRT.props
		which would override our definition of the UniversalCRT_IncludePath property.
		-->
		<UniversalCRT_PropsPath>NonExisting_UniversalCRT_PropsPath</UniversalCRT_PropsPath>

		<VC_VC_IncludePath>$compilerPackageDir\lib\native\include</VC_VC_IncludePath>
		<VC_ATLMFC_IncludePath>$compilerPackageDir\lib\native\atlmfc\include</VC_ATLMFC_IncludePath>
		<UniversalCRT_IncludePath>$sdkHeadersPackageDir\inc\ucrt</UniversalCRT_IncludePath>
		<UM_IncludePath>$sdkHeadersPackageDir\inc\coresdk</UM_IncludePath>
		<KIT_SHARED_IncludePath>$sdkHeadersPackageDir\inc\coresdk</KIT_SHARED_IncludePath>
		<WinRT_IncludePath>$sdkHeadersPackageDir\inc\rt</WinRT_IncludePath>
		<CppWinRT_IncludePath>$sdkHeadersPackageDir\inc\cppwinrt</CppWinRT_IncludePath>
		<DotNetSdk_IncludePath>$sdkHeadersPackageDir\inc\coresdk</DotNetSdk_IncludePath>
	</PropertyGroup>
</Project>
"@ | Out-File -FilePath $BuildPropsFileName -Encoding ascii

	LogComment "created build properties file `"$BuildPropsFileName`""
}
	
function CreateBuildTargetsFile($BuildTargetsFileName, $Packages, $ExportDefinitionFileBase) {
	# It might seem unusual to set properties in a *.targets file, but - even if additive -
	# $ExecutablePath assignments in the respective *.props file preclude assignments to the same
	# property by the rest of the build system (i.e. the build system appears to make $ExecutablePath
	# assignments only if the property is unset).

	$compilerPackageDir = GetNugetPackageInstallDir $Packages['Compiler']
	$sdkBinPackageDir = GetNugetPackageInstallDir $Packages['SDKBin']

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

		<ExecutablePath>$compilerPackageDir\lib\native\bin\`$(HostArchitecture)\`$(TargetArchitecture);`$(ExecutablePath)</ExecutablePath>
		<LibraryPath>$compilerPackageDir\lib\native\lib\`$(TargetArchitecture);$sdkBinPackageDir\lib\`$(TargetArchitecture);`$(LibraryPath)</LibraryPath>
	</PropertyGroup>

	<ItemDefinitionGroup>
		<ClCompile>
			<PreprocessorDefinitions>OFFICEDEV_DONT_POLLUTE_WINDOWS;%(PreprocessorDefinitions)</PreprocessorDefinitions>
			<ShowIncludes>true</ShowIncludes>
		</ClCompile>
		<Link>
			<AdditionalOptions>%(AdditionalOptions) /verbose</AdditionalOptions>
		</Link>
		<Link Condition="'`$(MSBuildProjectName)' == 'React.Windows.Desktop.DLL'">
			<ModuleDefinitionFile>$ExportDefinitionFileBase`$(TargetArchitecture).def</ModuleDefinitionFile>
		</Link>
	</ItemDefinitionGroup>
</Project>
"@ | Out-File -FilePath $BuildTargetsFileName -Encoding ascii

	LogComment "created build targets file `"$BuildTargetsFileName`""
}

[string] $FileOrDirNamePattern = "[^\\/*?:]*"
[string] $PathPattern = "[a-z]:(?:\\$FileOrDirNamePattern)*"

enum BuildLogParseMode {Neutral; Link; LinkSearchingLib}

function VerifyBuild($InstalledPackages, $BuildLogFile) {
	Write-Host -NoNewline "Verifying build "
	PushLogDeferral

	# Log file line number
	$lineNumber = 0

	# Office packages do not overwrite unit-test-related files like
	#     C:\Program Files (x86)\Microsoft Visual Studio\2017\Enterprise\VC\Auxiliary\VS\UnitTest\include\CppUnitTest.h
	# or
	#     C:\Program Files (x86)\Microsoft Visual Studio\2017\Enterprise\VC\Auxiliary\VS\UnitTest\lib\x64\Microsoft.VisualStudio.TestTools.CppUnitTestFramework.lib
	# We'll allow illegal headers and link inputs in the following projects:
	$projectWhitelist =
		"React.Windows.Desktop.UnitTests.vcxproj",
		"React.Windows.Desktop.IntegrationTests.vcxproj"

	function IsWhitelisted($item, $whitelist) {
		foreach ($whitelistItem in $whitelist) {
			if ($item.EndsWith($whitelistItem, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
		}
		return $false
	}

	function LogProjectMap {
		foreach ($project in $projectMap.Keys) {
			LogComment "project `"$project`""
			foreach ($header in $projectMap[$project].Headers) { LogComment "`theader `"$header`"" }
			foreach ($lib in $projectMap[$project].Libs) { LogComment "`tlib `"$lib`"" }
		}
	}

	# Mode enabling context-sensitive parsing of the log file.
	$mode = [BuildLogParseMode]::Neutral

	# Counts how often the Office compiler and linker was called.
	$officeCompilerCallCount = 0
	$officeLinkerCallCount = 0

	# Header and lib file paths rooted in these directories are considered 'legal'.
	$legalInputBaseDirs = (Split-Path $ProjectRootDir), $PackageTargetDirectory

	# Stack representing the project (.vcxproj) nesting structure.
	$projectStack = [System.Collections.Stack]::new()

	$projectMap = @{}

	# Link input currently searched by the linker for symbol definitions.
	[string] $currentLibPath = $null

	try {

		foreach ($chunk in Get-Content $buildLogFile -ReadCount 1000) {
			Write-Host -NoNewline "." # poor man's progress indicator

			foreach ($line in $chunk) {
				switch -regex ($line) {

					# Compiler Invocations
					#
					# Example:
					#   D:\ISS\private-rnw\vnext\packages\VisualCppTools.InternalAddCHPE.VS2017Layout.14.13.26133.2\lib\native\bin\Hostx64\x64\CL.exe /c /I ...
					#
					# Trailing space in pattern is meant to differentiate between compiler invocations and
					# AppxManifestMetadata decls.
					"^\s*(?<Path>$PathPattern)\\cl\.exe\s" { 
						if (!$Matches.Path.StartsWith((GetNugetPackageInstallDir $InstalledPackages.Compiler))) {
							LogError "It appears a non-Office compiler (`"$($Matches.Path)\cl.exe`") has been called during an Office build."
						} else {
							++$officeCompilerCallCount
						}

						break
					}

					# Linker Invocation
					#
					# Example:
					#   D:\ISS\private-rnw\vnext\packages\VisualCppTools.InternalAddCHPE.VS2017Layout.14.13.26133.2\lib\native\bin\Hostx64\x64\link.exe /ERRORREPORT:QUEUE ...
					"^\s*(?<Path>$PathPattern)\\link\.exe\s" {
						if (!$Matches.Path.StartsWith((GetNugetPackageInstallDir $InstalledPackages.Compiler))) {
							LogError "It appears a non-Office linker (`"$($Matches.Path)\link.exe`") has been called during an Office build."
						} else {
							++$officeLinkerCallCount
						}
						break
					}

					# ShowIncludes
					#
					# Example:
					#       Note: including file:  D:\ISS\private-rnw\vnext\packages\VisualCppTools.InternalAddCHPE.VS2017Layout.14.13.26133.2\lib\native\include\cstdlib (TaskId:31)
					"^\s*Note:\s+including file:\s+(?<Path>$PathPattern)\s+\(TaskId:\d+\)" {
						[void] $projectMap[$projectStack.Peek().ProjectFile].Headers.Add($Matches.Path.ToLower())
						break
					}

					# Start of Solution
					#
					# Example:
					#     Project "D:\ISS\private-rnw\vnext\ReactWindows-Desktop.sln" on node 1 (default targets).
					"^\s*Project `"(?<ProjFile>[^`"]+)`" on node \d+ \(default targets\)\.$" {
						$projectStack.push(@{LineNumber = $lineNumber; ProjectFile = $Matches.ProjFile})

						if (!$projectMap.ContainsKey($Matches.ProjFile)) {
							$projectMap.Add($Matches.ProjFile, @{
								# Sets for automatic de-duping.
								Headers = [System.Collections.Generic.HashSet`1[string]]::new()
								Libs = [System.Collections.Generic.HashSet`1[string]]::new()
							})
						}
						break
					}

					# Start of Project
					#
					# Example:
					#     Project "D:\ISS\private-rnw\vnext\ReactCommon\ReactCommon.vcxproj" (6:4) is building "D:\ISS\private-rnw\vnext\Folly\Folly.vcxproj" (2:9) on node 1 (GetResolvedLinkLibs target(s)).
					"^\s*Project `"[^`"]+`" \(\d+(?:\:\d+)?\) is building `"(?<ProjFile>[^`"]+)`"" {
						$projectStack.push(@{LineNumber = $lineNumber; ProjectFile = $Matches.ProjFile})
						if (!$projectMap.ContainsKey($Matches.ProjFile)) {
							$projectMap.Add($Matches.ProjFile, @{
								# Sets for automatic de-duping.
								Headers = [System.Collections.Generic.HashSet`1[string]]::new()
								Libs = [System.Collections.Generic.HashSet`1[string]]::new()
							})
						}
						break
					}

					# End of Project
					#
					# Example:
					#   Done Building Project "D:\ISS\private-rnw\vnext\Folly\Folly.vcxproj" (default targets).
					"^\s*Done Building Project `"(?<ProjFile>[^`"]+)`"" {
						Assert ($projectStack.Peek().ProjectFile -ieq $Matches.ProjFile) "log line $($lineNumber): unmatched project end (`"$($Matches.ProjFile)`")"
						[void] $projectStack.Pop()
						break
					}

					# Start of Link Task
					#
					# Example:
					#   Task "Link" (TaskId:573)
					"^\s*Task `"Link`" \(TaskId:\d+\)$" {
						Assert ($mode -eq [BuildLogParseMode]::Neutral) "expected 'Neutral', found $mode"
						$mode = [BuildLogParseMode]::Link
						break
					}

					# End of Link Task
					#
					# Example:
					#   Done executing task "Link". (TaskId:573)
					"^\s*Done executing task `"Link`". \(TaskId:\d+\)$" {
						Assert ($mode -eq [BuildLogParseMode]::Link -or $mode -eq [BuildLogParseMode]::LinkSearchingLib) "expected 'Link', found $mode"
						$mode = [BuildLogParseMode]::Neutral
						break
					}

					# Searching a Lib
					#
					# Example:
					#   Searching D:\ISS\private-rnw\vnext\packages\ReactWindows.OpenSSL.StdCall.Static.1.0.2-p.2\build\native\..\..\lib\x64\Debug\libeay32.lib: (TaskId:573)

					"^\s*Searching (?<LibPath>$PathPattern): \(TaskId:\d+\)$" {
						Assert (($mode -eq [BuildLogParseMode]::Link) -or ($mode -eq [BuildLogParseMode]::LinkSearchingLib)) "expected 'Link' or 'LinkSearchingLb', found $mode"
		
						$mode = [BuildLogParseMode]::LinkSearchingLib
						$currentLibPath = $Matches.LibPath
						break
					}

					# Loaded a Lib
					#
					# Example:
					#   Loaded libeay32.lib(ex_data.obj) (TaskId:573)
					# Can't use 'FileNamePattern' here because we need to exclude the parenthesized .obj name.
					"^\s*Loaded (?<LibBaseName>[^\\/*?:\(\)]*)" {
						Assert ($mode -eq [BuildLogParseMode]::LinkSearchingLib) "line $lineNumber; expected 'LinkSearchingLib', found $mode"
						Assert ($currentLibPath.EndsWith($Matches.LibBaseName, [System.StringComparison]::OrdinalIgnoreCase))

						[void] $projectMap[$projectStack.Peek().ProjectFile].Libs.Add($currentLibPath.ToLower())

						# Not changing mode as there can be multiple 'Loaded' messages for a lib
						# (one per reference it resolves).
						break
					}
				}

				++$lineNumber
			}
		}

		if ($officeCompilerCallCount -eq 0) { LogError "Office compiler was not called during an Office build. $officeCompilerCallCount" }
		if ($officeLinkerCallCount -eq 0) { LogError "Office linker was not called during an Office build. $officeLinkerCallCount" }

		# LogProjectMap # for debugging

		foreach ($project in $projectMap.Keys) {
			if (!(IsWhitelisted $project $projectWhitelist)) {

				foreach ($header in $projectMap[$project].Headers) {
					$isLegal = $false
					foreach($legalInputBaseDir in $legalInputBaseDirs) {
						if ($header.StartsWith($legalInputBaseDir, [System.StringComparison]::OrdinalIgnoreCase)) {
							$isLegal = $true
							break
						}
					}
					if (!$isLegal) { LogError "`"$header`" might be an illegal header" }
				}

				foreach ($lib in $projectMap[$project].Libs) {
					$isLegal = $false
					foreach($legalInputBaseDir in $legalInputBaseDirs) {
						if ($lib.StartsWith($legalInputBaseDir, [System.StringComparison]::OrdinalIgnoreCase)) {
							$isLegal = $true
							break
						}
					}
					if (!$isLegal) { LogError "`"$lib`" might be an illegal link input" }
				}
			}
		}

	} finally {
		Write-Host " done."
		PopLogDeferral
	}
}

#endregion

#region User-Callable Actions

function Install() {
	if ($UseNuget) {
		# It seems nuget.exe requires the "packages.config" file name (other file names are being
		# interpreted as package names).
		$packageConfigFile = "$($env:TEMP)\packages.config"
		CreatePackageConfig $ScriptConfigurationData.packages $packageConfigFile
		Write-Host "Ensuring packages are installed ... " -NoNewline

		# $nugetCommand = "&`"$NugetCmd`" setapikey $APIKey -Source `"$($ScriptConfigurationData.feeds.OfficeNugetFeed.url)`""
		# LogComment "NuGet command `"$nugetCommand`""
		# $nugetOutput = Invoke-Expression $nugetCommand
		# foreach ($line in $nugetOutput) { LogComment $line }

		$nugetCommand = "&`"$NugetCmd`" install -Source `"$($ScriptConfigurationData.feeds.OfficeNugetFeed.url)`" `"$packageConfigFile`" -OutputDirectory `"$PackageTargetDirectory`""
		LogComment "NuGet command `"$nugetCommand`""
		$nugetOutput = Invoke-Expression $nugetCommand
		foreach ($line in $nugetOutput) { LogComment $line }
		Assert ($LASTEXITCODE -eq 0) "`"$NugetCmd`" ended with a non-zero exit code"
		Write-Host "done."
	} else {

		RegisterFeeds
		try {
			foreach ($key in $ScriptConfigurationData.packages.Keys) {
				$packageInfo = $ScriptConfigurationData.packages[$key]

				Write-Host "Installing package $($packageInfo.name) $($pi.version) ... " -NoNewline
				InstallNugetPackage -Name $pi.name -Version $pi.version -Feed $pi.feed -Credential $ScriptConfigurationData.feeds[$pi.feed].credential
				Write-Host "done."
			}
		} finally {
			UnregisterFeeds
		}
	}

	$installedPackages = GetInstalledPackages $ScriptConfigurationData.packages
	FixUpHeaders $installedPackages
	return $installedPackages
}

function Uninstall() {
	$packages = GetInstalledPackages $ScriptConfigurationData.packages

	foreach ($key in $packages.Keys) {
		$package = $packages[$key]
		Write-Host "Uninstalling package $($package.Name) $($package.Version) ... " -NoNewline
		UninstallNugetPackage -Name $package.Name -Version $package.Version
		Write-Host "done."
	}
}

function Build(
	[string] $SolutionFileName,
	[ValidateSet('x64', 'x86')][string] $Platform,
	[ValidateSet('Release', 'Debug')][string] $Configuration) {

	$originalExportDefinitionFileName = "$ProjectRootDir\Desktop.DLL\react-native-win32.$Platform.def"
	$modifiedExportDefinitionFileBase = "$env:TEMP\ReactNativeWindows-$ScriptName-Build-"
	$modifiedExportDefinitionFileName = "$modifiedExportDefinitionFileBase$Platform.def"
	$propsFileName = "$env:TEMP\ReactNativeWindows-$ScriptName-Build.props"
	$targetsFileName = "$env:TEMP\ReactNativeWindows-$ScriptName-Build.targets"
	$logFileName = "$env:TEMP\ReactNativeWindows-$ScriptName-Build-$Platform-$Configuration.log"

	PushLogDeferral
	try {
		# Build implies install
		$installedPackages = Install

		CreateExportDefinitionFile $originalExportDefinitionFileName $modifiedExportDefinitionFileName

		# Props and targets files are platform- and configuration-independent, their creation
		# could be factored out of this function.
		CreateBuildPropsFile $propsFileName $installedPackages
		CreateBuildTargetsFile $targetsFileName $installedPackages $modifiedExportDefinitionFileBase
		$buildCommand = "&`"$MSBuildCmd`" /v:diag /p:Platform=$Platform /p:Configuration=$Configuration /p:RNWBuildOverrideProps=$propsFileName /p:RNWBuildOverrideTargets=$targetsFileName /p:NoCppWinRT=true $SolutionFileName > `"$logFileName`""
		LogComment "build command `"$buildCommand`""
		Write-Host "Building ..." -NoNewline
		LogComment "build starting"
		Invoke-Expression $buildCommand # diagnostic build output is too long to capture it as a list of lines
		LogAppend $logFileName
		Assert ($LASTEXITCODE -eq 0) "`"MSBuildCmd`" ended with a non-zero exit code"
		LogComment "build finished"
		Write-Host " done."

		VerifyBuild $installedPackages $logFileName
	} finally {
		PopLogDeferral
	}
}

#endregion

#region Main

$startTime = Get-Date
try {
	switch ($Action) {
		'install' { [void] (Install) }
		'uninstall' { Uninstall }
		'build' { Build $BuildSolution $BuildPlatform $BuildConfiguration }
		'_verifybuild' {
			$installedPackages = Install
			$logFileName = "$env:TEMP\ReactNativeWindows-$ScriptName-Build-$BuildPlatform-$BuildConfiguration.log"
			VerifyBuild $installedPackages $logFileName
		}

		default { throw "unexpected action $Action" }
	}
} catch {
	LogError "terminating due to critical error '$($_.Exception.Message)', trace $($_.Exception.StackTrace)"
} finally {
	Write-Host "errors: $ErrorCount, warnings: $WarningCount, total time: $((Get-Date) - $startTime)"

	if (!$ADOLog) {
		Write-Host "details in `"$LogFile`""
	}

	exit (0, 1)[$ErrorCount -gt 0]
}

#endregion
