Param(
  [string]$platform = "x64",
  [string]$pythonversion = "3.13_10",
  [string]$SignX509Thumbprint = $null,
  [string]$release = $null,
  # Cloudbase-Init repo details
  [string]$CloudbaseInitRepoUrl = "https://github.com/cloudbase/cloudbase-init.git",
  [string]$CloudbaseInitRepoBranch = "master",
  # Use an already available installer or clone a new one.
  [switch]$ClonePullInstallerRepo = $true,
  [string]$InstallerDir = $null,
  [string]$VSRedistDir = "${ENV:ProgramFiles(x86)}\Common Files\Merge Modules",
  [string]$SignTimestampUrl = "http://timestamp.digicert.com?alg=sha256"
)

$ErrorActionPreference = "Stop"

$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
. "$scriptPath\BuildUtils.ps1"

$platformVCVarsRequired = "x86_amd64"
# On Visual Studio 2019, the mixed x86_amd64 VC variables
# make compilation for x86 use the x64 functions
if ($platform -eq "x86") {
    $platformVCVarsRequired = "x86"
}

SetVCVars "2019" $platformVCVarsRequired

# Needed for SSH
$ENV:HOME = $ENV:USERPROFILE

$python_dir = "C:\Python_CloudbaseInit"

$ENV:PATH = "$python_dir\;$python_dir\scripts;$ENV:PATH"
$ENV:PATH += ";$ENV:ProgramFiles (x86)\Git\bin\"
$ENV:PATH += ";$ENV:ProgramFiles\7-zip\"

$basepath = "C:\build\cloudbase-init"
CheckDir $basepath

pushd .
try
{
    cd $basepath

    # Don't use the default pip temp directory to avoid concurrency issues
    $ENV:TMPDIR = Join-Path $basepath "temp"
    CheckRemoveDir $ENV:TMPDIR
    mkdir $ENV:TMPDIR

    if ($ClonePullInstallerRepo)
    {
        # Clone a new installer repo no matter what.
        $cloudbaseInitInstallerDir = join-Path $basepath "cloudbase-init-installer"
        ExecRetry {
            GitClonePull $cloudbaseInitInstallerDir "https://github.com/cloudbase/cloudbase-init-installer.git"
        }
    }
    else
    {
        if (!$InstallerDir)
        {
            # No path provided, so use the current installer script path.
            $InstallerDir = (Join-Path -Path $PSScriptRoot -ChildPath ..\ -Resolve)
        }
        if (Test-Path $InstallerDir)
        {
            $cloudbaseInitInstallerDir = $InstallerDir
        }
        else
        {
            throw "Installer path not present: $InstallerDir"
        }
    }

    $python_template_dir = join-path $cloudbaseInitInstallerDir "Python$($pythonversion.replace('.', ''))_${platform}_Template"

    CheckCopyDir $python_template_dir $python_dir

    # Make sure that we don't have temp files from a previous build
    $python_build_path = "$ENV:LOCALAPPDATA\Temp\pip_build_$ENV:USERNAME"
    if (Test-Path $python_build_path) {
        Remove-Item -Recurse -Force $python_build_path
    }

    ExecRetry { PipInstall "pip" -update $true }
    ExecRetry { PipInstall "wheel" -update $true }
    ExecRetry { PipInstall "setuptools" -update $true }

    if (Test-Path ".\requirements") {
        Remove-Item -Recurse -Force ".\requirements"
    }

    mkdir ".\requirements"
    $upper_constraints_path = ".\requirements\upper-constraints.txt"
    $upper_constraints_file = Join-Path (Resolve-Path ".\requirements") "upper-constraints.txt"
    try {
        ExecRetry { DownloadFile "https://raw.githubusercontent.com/cloudbase/cloudbase-init/refs/heads/${CloudbaseInitRepoBranch}/upper-constraints.txt" $upper_constraints_file }
    } catch {
        ExecRetry { DownloadFile "https://raw.githubusercontent.com/openstack/requirements/refs/heads/master/upper-constraints.txt" $upper_constraints_file }
    }

    if (!(Test-Path $upper_constraints_file)) {
      throw "${upper_constraints_file} does not exist"
    }

    $env:PIP_CONSTRAINT = $upper_constraints_file
    $env:PIP_NO_BINARIES = "cloudbase-init"

    if ($release)
    {
        ExecRetry { PipInstall "cloudbase-init==$release" }
    }
    else
    {
        ExecRetry { PullInstall "cloudbase-init" $CloudbaseInitRepoUrl $CloudbaseInitRepoBranch }
    }

    $release_dir = join-path $cloudbaseInitInstallerDir "CloudbaseInitSetup\bin\Release\$platform"
    $bin_dir = join-path $cloudbaseInitInstallerDir "CloudbaseInitSetup\Binaries\$platform"

    $zip_content_dir = join-path $release_dir "zip_content"
    CheckRemoveDir $zip_content_dir
    mkdir $zip_content_dir

    $python_dir_release = join-path $zip_content_dir "Python"
    $bin_dir_release = join-path $zip_content_dir "Bin"

    CheckCopyDir $python_dir $python_dir_release
    CheckCopyDir $bin_dir $bin_dir_release

    $zip_path = join-path $release_dir "CloudbaseInitSetup.zip"
    if (Test-Path $zip_path) {
        del $zip_path
    }

    pushd $zip_content_dir
    try
    {
        CreateZip $zip_path *
    }
    finally
    {
        popd
    }

    $version = &"$python_dir\python.exe" -c "from cloudbaseinit import version; print(version.get_version())"
    if ($LastExitCode -or !$version.Length) { throw "Unable to get cloudbase-init version" }
    Write-Host "Cloudbase-Init version: $version"

    try
    {
        [int]::Parse($version.Substring($version.LastIndexOf('.') + 1)) | out-null
        $msi_version = $version + ".0"
        Write-Host "This is a tagged stable release"
    }
    catch
    {
        $msi_version = $version.Substring(0, $version.LastIndexOf('.')) + ".0"
    }

    Write-Host "Cloudbase-Init MSI version: $msi_version"

    $installer_sources_dir = join-path $cloudbaseInitInstallerDir "CloudbaseInitSetup"

    # Dynamically detect Visual C++ CRT merge module path (VC140 for VS2015-2019, VC143 for VS2022)
    $vcMsmVersion = "140"
    $vcYear = "2019"
    $msvcEdition = "Community"
    $msmRedistDir = "${ENV:ProgramFiles(x86)}\Common Files\Merge Modules"
    $vsRoot = $null
    $foundMsm = $false

    # Try to infer used Visual Studio version/toolset from current environment or script logic
    # Prefer VC143 if VS2022, else VC140 as fallback
    try {
        # Detect if used version is VS2022
        $vswherePath = "${ENV:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path $vswherePath) {
            $vs2022Path = & $vswherePath -version "17.0" -products * -property installationPath -latest | Select-Object -First 1
            if ($vs2022Path) {
                $msvcEdition = "Community"
                $vcRedistDir2022 = Join-Path $vs2022Path "VC\Redist\MSVC"
                if (Test-Path $vcRedistDir2022) {
                    $msvcDirs = Get-ChildItem $vcRedistDir2022 | Sort-Object Name -Descending
                    foreach ($dir in $msvcDirs) {
                        $mergeModulesPath = Join-Path $dir.FullName "MergeModules"
                        if (Test-Path $mergeModulesPath) {
                            $vcMsmVersion = "143"
                            $msmRedistDir = $mergeModulesPath
                            $vcYear = "2022"
                            $foundMsm = $true
                            break
                        }
                    }
                }
            }
        }
    } catch {}

    if (!$foundMsm) {
        # Default to legacy 2019/2017 merge module location
        $vcMsmVersion = "140"
        $vcYear = "2019"
        $msmRedistDir = "${ENV:ProgramFiles(x86)}\Common Files\Merge Modules"
    }

    if($platform -eq "x64")
    {
        $crtMsm = "Microsoft_VC${vcMsmVersion}_CRT_x64.msm"
    }
    else
    {
        $crtMsm = "Microsoft_VC${vcMsmVersion}_CRT_x86.msm"
    }
    $crtMsmPath = Join-Path $msmRedistDir $crtMsm
    if (Test-Path $crtMsmPath) {
        copy $crtMsmPath $installer_sources_dir
        Write-Host "Copied CRT merge module: $crtMsmPath"
    } else {
        Write-Warning "Could not find CRT merge module at: $crtMsmPath. Make sure the C++ merge modules are installed for Visual Studio $vcYear."
    }

    cd $cloudbaseInitInstallerDir

    &msbuild CloudbaseInitSetup.sln /m /p:Platform=$platform /p:Configuration=`"Release`"  /p:DefineConstants=`"PythonSourcePath=$python_dir`;CarbonSourcePath=Carbon`;Version=$msi_version`;VersionStr=$version`"
    if ($LastExitCode) { throw "MSBuild failed" }

    $msi_path = join-path $cloudbaseInitInstallerDir "CloudbaseInitSetup\bin\Release\$platform\CloudbaseInitSetup.msi"

    if($SignX509Thumbprint)
    {
        ExecRetry {
            Write-Host "Signing MSI with certificate: $SignX509Thumbprint"
            signtool.exe sign /sha1 $SignX509Thumbprint /tr $SignTimestampUrl /td SHA256 /v $msi_path
            if ($LastExitCode) { throw "signtool failed" }
        }
    }
    else
    {
        Write-Warning "MSI not signed"
    }

    Remove-Item -Recurse -Force $python_dir
}
finally
{
    popd
}
