# This script uses code of Fido by Pete Batard:
#
# Copyright © 2019-2025 Pete Batard <pete@akeo.ie>
# Command line support: Copyright © 2021 flx5
# ConvertTo-ImageSource: Copyright © 2016 Chris Carter
#
# License of original Fido: GNU General Public License

#region Parameters
param(
	# (Optional) The title to display on the application window.
	[string]$AppTitle = "FidoArch - Archive.org ISO Downloader",

	# (Optional) '|' separated UI localization strings.
	[string]$LocData,

	# (Optional) Forced locale
	[string]$Locale = "en-US",

	# (Optional) Path to a file that should be used for the UI icon.
	[string]$Icon,

	# (Optional) Name of a pipe the download URL should be sent to.
	# If not provided, a browser window is opened instead.
	[string]$PipeName,

	# (Optional) Only display the download URL [Toggles commandline mode]
	[switch]$GetUrl = $false,

	# (Optional) Download with PowerShell [Toggles commandline mode]
	[switch]$InternalDownload = $false,

	# (Optional) Increase verbosity
	[switch]$Verbose = $false,

	# (Optional) Produce debugging information
	[switch]$Debug = $false
)
#endregion

try {
	[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$Cmd = $false
if ($InternalDownload -or $GetUrl -or $Debug) {
	$Cmd = $true
}

# Return a decimal Windows version that we can then check for platform support.
# Note that because we don't want to have to support this script on anything
# other than Windows, this call returns 0.0 for PowerShell running on Linux/Mac.
function Get-Platform-Version()
{
	$version = 0.0
	$platform = [string][System.Environment]::OSVersion.Platform
	# This will filter out non Windows platforms
	if ($platform.StartsWith("Win")) {
		# Craft a decimal numeric version of Windows
		$version = [System.Environment]::OSVersion.Version.Major * 1.0 + [System.Environment]::OSVersion.Version.Minor * 0.1
	}
	return $version
}

$winver = Get-Platform-Version

# The default TLS for Windows 8.x doesn't work with Microsoft's servers so we must force it
if ($winver -lt 10.0) {
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12
}

#region Assembly Types
$Drawing_Assembly = "System.Drawing"
# PowerShell 7 altered the name of the Drawing assembly...
if ($host.version -ge "7.0") {
	$Drawing_Assembly += ".Common"
}

$Signature = @{
	Namespace            = "WinAPI"
	Name                 = "Utils"
	Language             = "CSharp"
	UsingNamespace       = "System.Runtime", "System.IO", "System.Text", "System.Drawing", "System.Globalization"
	ReferencedAssemblies = $Drawing_Assembly
	ErrorAction          = "Stop"
	WarningAction        = "Ignore"
	IgnoreWarnings       = $true
	MemberDefinition     = @"
		[DllImport("shell32.dll", CharSet = CharSet.Auto, SetLastError = true, BestFitMapping = false, ThrowOnUnmappableChar = true)]
		internal static extern int ExtractIconEx(string sFile, int iIndex, out IntPtr piLargeVersion, out IntPtr piSmallVersion, int amountIcons);

		[DllImport("user32.dll")]
		public static extern bool ShowWindow(IntPtr handle, int state);
		// Extract an icon from a DLL
		public static Icon ExtractIcon(string file, int number, bool largeIcon) {
			IntPtr large, small;
			ExtractIconEx(file, number, out large, out small, 1);
			try {
				return Icon.FromHandle(largeIcon ? large : small);
			} catch {
				return null;
			}
		}
"@
}

Write-Host Please Wait...

if (!("WinAPI.Utils" -as [type]))
{
	Add-Type @Signature
}
Add-Type -AssemblyName PresentationFramework

if (!$Cmd) {
	# Hide the powershell window: https://stackoverflow.com/a/27992426/1069307
	[WinAPI.Utils]::ShowWindow(([System.Diagnostics.Process]::GetCurrentProcess() | Get-Process).MainWindowHandle, 0) | Out-Null
}
#endregion

#region Data
$WindowsVersions = @(
	@(
		@("Windows 11"),
		@("24H2"),
		@("23H2"),
		@("22H2"),
		@("21H2")
	),
	@(
		@("Windows 10"),
		@("22H2"),
		@("21H2"),
		@("21H1"),
		@("20H2"),
		@("2004"),
		@("1909"),
		@("1903"),
		@("1809"),
		@("1803"),
		@("1709"),
		@("1703"),
		@("1607"),
		@("1511"),
		@("1507")
	),
	@(
		@("Windows 8.1"),
		@("-")
	),
	@(
		@("Windows 8"),
		@("-")
	),
	@(
		@("Windows 7"),
		@("-")
	),
	@(
		@("Windows Vista"),
		@("-")
	),
	@(
		@("Windows XP"),
		@("-")
	),
	@(
		@("Windows 2000"),
		@("-")
	),
	@(
		@("Windows NT 4.0"),
		@("-")
	),
	@(
		@("Windows NT 3.51"),
		@("-")
	),
	@(
		@("Windows NT 3.5"),
		@("-")
	),
	@(
		@("Windows NT 3.1"),
		@("-")
	),
	@(
		@("Windows ME"),
		@("-")
	),
	@(
		@("Windows 98"),
		@("-")
	),
	@(
		@("Windows 95"),
		@("-")
	)
)
#endregion

#region Globals
$ErrorActionPreference = "Stop"
$DefaultTimeout = 30
$dh = 58
$Stage = 0
$SelectedIndex = 0
$ExitCode = 100
$Locale = $Locale
$Verbosity = 1
if ($Debug) {
	$Verbosity = 5
} elseif ($Verbose) {
	$Verbosity = 2
}
#endregion

#region Localization
$EnglishMessages = "en-US|Version|Release|Edition|Language|Architecture|Download|Continue|Back|Close|Cancel|Error|Please wait...|" +
	"Download using a browser|Download of Windows ISOs is unavailable due to Microsoft having altered their website to prevent it.|" +
	"PowerShell 3.0 or later is required to run this script.|Do you want to go online and download it?|" +
	"This feature is not available on this platform."
[string[]]$English = $EnglishMessages.Split('|')
[string[]]$Localized = $null
if ($LocData -and !$LocData.StartsWith("en-US")) {
	$Localized = $LocData.Split('|')
	# Adjust the $Localized array if we have more or fewer strings than in $EnglishMessages
	if ($Localized.Length -lt $English.Length) {
		while ($Localized.Length -ne $English.Length) {
			$Localized += $English[$Localized.Length]
		}
	} elseif ($Localized.Length -gt $English.Length) {
		$Localized = $LocData.Split('|')[0..($English.Length - 1)]
	}
	$Locale = $Localized[0]
}
$QueryLocale = $Locale
#endregion

#region Functions
# Convert a size in bytes to a human readable string
function Size-To-Human-Readable([uint64]$size)
{
	$suffix = "bytes", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"
	$i = 0
	while ($size -gt 1kb) {
		$size = $size / 1kb
		$i++
	}
	"{0:N1} {1}" -f $size, $suffix[$i]
}

function Add-Entry([int]$pos, [string]$Name, [array]$Items, [string]$DisplayName)
{
	$Title = New-Object System.Windows.Controls.TextBlock
	$Title.FontSize = $WindowsVersionTitle.FontSize
	$Title.Height = $WindowsVersionTitle.Height;
	$Title.Width = $WindowsVersionTitle.Width;
	$Title.HorizontalAlignment = "Left"
	$Title.VerticalAlignment = "Top"
	$Margin = $WindowsVersionTitle.Margin
	$Margin.Top += $pos * $dh
	$Title.Margin = $Margin
	$Title.Text = Get-Translation($Name)
	$XMLGrid.Children.Insert(2 * $Stage + 2, $Title)

	$Combo = New-Object System.Windows.Controls.ComboBox
	$Combo.FontSize = $WindowsVersion.FontSize
	$Combo.Height = $WindowsVersion.Height;
	$Combo.Width = $WindowsVersion.Width;
	$Combo.HorizontalAlignment = "Left"
	$Combo.VerticalAlignment = "Top"
	$Margin = $WindowsVersion.Margin
	$Margin.Top += $pos * $script:dh
	$Combo.Margin = $Margin
	$Combo.SelectedIndex = 0
	if ($Items) {
		$Combo.ItemsSource = $Items
		if ($DisplayName) {
			$Combo.DisplayMemberPath = $DisplayName
		} else {
			$Combo.DisplayMemberPath = $Name
		}
	}
	$XMLGrid.Children.Insert(2 * $Stage + 3, $Combo)

	$XMLForm.Height += $dh;
	$Margin = $Continue.Margin
	$Margin.Top += $dh
	$Continue.Margin = $Margin
	$Margin = $Back.Margin
	$Margin.Top += $dh
	$Back.Margin = $Margin

	return $Combo
}

function Refresh-Control([object]$Control)
{
	$Control.Dispatcher.Invoke("Render", [Windows.Input.InputEventHandler] { $Continue.UpdateLayout() }, $null, $null) | Out-Null
}

function Send-Message([string]$PipeName, [string]$Message)
{
	[System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8
	$Pipe = New-Object -TypeName System.IO.Pipes.NamedPipeClientStream -ArgumentList ".", $PipeName, ([System.IO.Pipes.PipeDirection]::Out), ([System.IO.Pipes.PipeOptions]::None), ([System.Security.Principal.TokenImpersonationLevel]::Impersonation)
	try {
		$Pipe.Connect(1000)
	} catch {
		Write-Host $_.Exception.Message
	}
	$bRequest = $Encoding.GetBytes($Message)
	$cbRequest = $bRequest.Length;
	$Pipe.Write($bRequest, 0, $cbRequest);
	$Pipe.Dispose()
}

# From https://www.powershellgallery.com/packages/IconForGUI/1.5.2
# Copyright © 2016 Chris Carter. All rights reserved.
# License: https://creativecommons.org/licenses/by-sa/4.0/
function ConvertTo-ImageSource
{
	[CmdletBinding()]
	Param(
		[Parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
		[System.Drawing.Icon]$Icon
	)

	Process {
		foreach ($i in $Icon) {
			[System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
				$i.Handle,
				(New-Object System.Windows.Int32Rect -Args 0,0,$i.Width, $i.Height),
				[System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
			)
		}
	}
}

# Translate a message string
function Get-Translation([string]$Text)
{
	if (!($English -contains $Text)) {
		Write-Host "Error: '$Text' is not a translatable string"
		return "(Untranslated)"
	}
	if ($Localized) {
		if ($Localized.Length -ne $English.Length) {
			Write-Host "Error: '$Text' is not a translatable string"
		}
		for ($i = 0; $i -lt $English.Length; $i++) {
			if ($English[$i] -eq $Text) {
				if ($Localized[$i]) {
					return $Localized[$i]
				} else {
					return $Text
				}
			}
		}
	}
	return $Text
}

# Return an array of releases (e.g. 20H2, 21H1, ...) for the selected Windows version
function Get-Windows-Releases([int]$SelectedVersion)
{
	$i = 0
	$releases = @()
	foreach ($version in $WindowsVersions[$SelectedVersion]) {
		if (($i -ne 0) -and ($version -is [array])) {
			$releases += @(New-Object PsObject -Property @{ Release = $version[0]; Index = $i })
		}
		$i++
	}
	return $releases
}

# Return an array of editions (e.g. Home, Pro, etc) for the selected Windows release
function Get-Windows-Editions([string]$SelectedVersion, [string]$SelectedRelease)
{
	$editions = @()
	if ($SelectedRelease -like "-") {
		$win_flavor = $SelectedVersion
	} else {
		$win_flavor = "$($SelectedVersion) $($SelectedRelease)"
	}

	$win_flavor_esc = [URI]::EscapeUriString($win_flavor)
	$response = Invoke-WebRequest -Uri "https://archive.org/services/search/v1/scrape?q=%28%22$($win_flavor_esc)%22%29%20AND%20collection%3A%28cdromimages%29&fields=title" -UseBasicParsing
	$res = $response | ConvertFrom-Json
	foreach ($item in $res.items )
	{
		if ($item.title.StartsWith($win_flavor)) {
		    $editions += @(New-Object PsObject -Property @{ Edition = $item.title; Id = $item.identifier })
		}
		elseif ($item.title.StartsWith("Microsoft $($win_flavor)")) {
		    $editions += @(New-Object PsObject -Property @{ Edition = $item.title.Substring(10); Id = $item.identifier })
		}
	}
	return $editions
}

# Download files.xml, extract .iso URL
function Get-Iso-Url([string]$id)
{
	# parsing content bytes in memory often fails for whatever reason, so we download to TMP instead
	$tmp_file = "$($env:TEMP)\fido-arch-tmp.xml"
	$response = Invoke-WebRequest -Uri "https://archive.org/download/$($id)/$($id)_files.xml" -OutFile $tmp_file
	[xml]$xml = Get-Content $tmp_file
	Remove-Item -Path $tmp_file
	foreach ($file in $xml.files.file)
	{
		if ($file.format -like "ISO Image")
		{
			$file_esc = [URI]::EscapeUriString($file.name)
			return "https://archive.org/download/$($id)/$($file_esc)"
		}
	}
}

# Process the download URL by either sending it through the pipe or by opening the browser
function Process-Download-Link([string]$Url)
{
	try {
		if ($PipeName -and !$Check.IsChecked) {
			Send-Message -PipeName $PipeName -Message $Url
		} else {
			if ($InternalDownload) {
				$pattern = '.*\/(.*\.iso).*'
				$File = [regex]::Match($Url, $pattern).Groups[1].Value
				# PowerShell implicit conversions are iffy, so we need to force them...
				$str_size = (Invoke-WebRequest -UseBasicParsing -TimeoutSec $DefaultTimeout -Uri $Url -Method Head).Headers.'Content-Length'
				$tmp_size = [uint64]::Parse($str_size)
				$Size = Size-To-Human-Readable $tmp_size
				Write-Host "Downloading '$File' ($Size)..."
				Start-BitsTransfer -Source $Url -Destination $File
			} else {
				Write-Host Download Link: $Url
				Start-Process -FilePath $Url
			}
		}
	} catch {
		Error($_.Exception.Message)
		return 404
	}
	return 0
}
#endregion

#region Form
[xml]$XAML = @"
<Window xmlns = "http://schemas.microsoft.com/winfx/2006/xaml/presentation" Height = "162" Width = "384" ResizeMode = "NoResize">
	<Grid Name = "XMLGrid">
		<Button Name = "Continue" FontSize = "16" Height = "26" Width = "160" HorizontalAlignment = "Left" VerticalAlignment = "Top" Margin = "14,78,0,0"/>
		<Button Name = "Back" FontSize = "16" Height = "26" Width = "160" HorizontalAlignment = "Left" VerticalAlignment = "Top" Margin = "194,78,0,0"/>
		<TextBlock Name = "WindowsVersionTitle" FontSize = "16" Width="340" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="16,8,0,0"/>
		<ComboBox Name = "WindowsVersion" FontSize = "14" Height = "24" Width = "340" HorizontalAlignment = "Left" VerticalAlignment="Top" Margin = "14,34,0,0" SelectedIndex = "0"/>
		<CheckBox Name = "Check" FontSize = "14" Width = "340" HorizontalAlignment = "Left" VerticalAlignment="Top" Margin = "14,0,0,0" Visibility="Collapsed" />
	</Grid>
</Window>
"@
#endregion

# Form creation
$XMLForm = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $XAML))
$XAML.SelectNodes("//*[@Name]") | ForEach-Object { Set-Variable -Name ($_.Name) -Value $XMLForm.FindName($_.Name) -Scope Script }
$XMLForm.Title = $AppTitle

if ($Icon) {
	$XMLForm.Icon = $Icon
} else {
	$XMLForm.Icon = [WinAPI.Utils]::ExtractIcon("imageres.dll", -5205, $true) | ConvertTo-ImageSource
}

if ($Locale.StartsWith("ar") -or $Locale.StartsWith("fa") -or $Locale.StartsWith("he")) {
	$XMLForm.FlowDirection = "RightToLeft"
}
$WindowsVersionTitle.Text = Get-Translation("Version")
$Continue.Content = Get-Translation("Continue")
$Back.Content = Get-Translation("Close")

# Windows 7 and non Windows platforms are too much of a liability
if ($winver -le 6.1) {
	Error(Get-Translation("This feature is not available on this platform."))
	exit 403
}

# Populate the Windows versions
$i = 0
$versions = @()
foreach($version in $WindowsVersions) {
	$versions += @(New-Object PsObject -Property @{ Version = $version[0][0]; PageType = $version[0][1]; Index = $i })
	$i++
}
$WindowsVersion.ItemsSource = $versions
$WindowsVersion.DisplayMemberPath = "Version"

# Button Action
$Continue.add_click({
	$script:Stage++
	$XMLGrid.Children[2 * $Stage + 1].IsEnabled = $false
	$Continue.IsEnabled = $false
	$Back.IsEnabled = $false
	Refresh-Control($Continue)
	Refresh-Control($Back)

	switch ($Stage) {

		1 { # Windows Version selection
			$XMLForm.Title = Get-Translation($English[12])
			Refresh-Control($XMLForm)
			$releases = Get-Windows-Releases $WindowsVersion.SelectedValue.Index
			$script:WindowsRelease = Add-Entry $Stage "Release" $releases
			$Back.Content = Get-Translation($English[8])
			$XMLForm.Title = $AppTitle
		}

		2 { # Windows Release selection => Populate Product Edition
			$editions = Get-Windows-Editions $WindowsVersion.SelectedValue.Version $WindowsRelease.SelectedValue.Release
			$script:ProductEdition = Add-Entry $Stage "Edition" $editions
		}

		3 { # Edition selection => Return selected download link
			$url = Get-Iso-Url $ProductEdition.SelectedValue.Id
			if ($GetUrl) {
				Write-Host $url
				$ExitCode = 0
			} else {
				$script:ExitCode = Process-Download-Link $url
			}
			$XMLForm.Close()
		}
	}
	$Continue.IsEnabled = $true
	if ($Stage -ge 0) {
		$Back.IsEnabled = $true
	}
})

$Back.add_click({
	if ($Stage -eq 0) {
		$XMLForm.Close()
	} else {
		$XMLGrid.Children.RemoveAt(2 * $Stage + 3)
		$XMLGrid.Children.RemoveAt(2 * $Stage + 2)
		$XMLGrid.Children[2 * $Stage + 1].IsEnabled = $true
		$dh2 = $dh
		if ($Stage -eq 4 -and $PipeName) {
			$Check.Visibility = "Collapsed"
			$dh2 += $dh / 2
		}
		$XMLForm.Height -= $dh2;
		$Margin = $Continue.Margin
		$Margin.Top -= $dh2
		$Continue.Margin = $Margin
		$Margin = $Back.Margin
		$Margin.Top -= $dh2
		$Back.Margin = $Margin
		$script:Stage = $Stage - 1
		$XMLForm.Title = $AppTitle
		if ($Stage -eq 0) {
			$Back.Content = Get-Translation("Close")
		} else {
			$Continue.Content = Get-Translation("Continue")
			Refresh-Control($Continue)
		}
	}
})

# Display the dialog
$XMLForm.Add_Loaded({$XMLForm.Activate()})
$XMLForm.ShowDialog() | Out-Null

# Clean up & exit
exit $ExitCode
