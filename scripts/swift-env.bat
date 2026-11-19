@echo off
rem Swift on Windows needs the MSVC environment on PATH before it can find the
rem Windows SDK module maps; without it every command fails with
rem "unable to load standard library for target x86_64-unknown-windows-msvc".
rem
rem Usage:  scripts\swift-env.bat swift test
rem         scripts\swift-env.bat swift build

setlocal

rem vcvars64.bat itself shells out to vswhere.exe, which is not on PATH by
rem default. Without this it "succeeds" while setting nothing up.
set "PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer;%PATH%"

set "VCVARS="
for %%P in (
  "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
) do if not defined VCVARS if exist %%P set "VCVARS=%%~P"

if not defined VCVARS (
  echo Could not find vcvars64.bat.
  echo Install Visual Studio Build Tools 2022 with the C++ workload and the Windows SDK.
  exit /b 1
)

call "%VCVARS%" >nul
if errorlevel 1 exit /b 1

set "SWIFT_BIN=%LOCALAPPDATA%\Programs\Swift\Toolchains\6.4.2+Asserts\usr\bin"
if not exist "%SWIFT_BIN%\swift.exe" (
  rem Fall back to whatever single toolchain is installed.
  for /d %%T in ("%LOCALAPPDATA%\Programs\Swift\Toolchains\*") do set "SWIFT_BIN=%%T\usr\bin"
)
set "PATH=%SWIFT_BIN%;%PATH%"

rem The Swift runtime DLLs are installed separately from the toolchain. Without
rem them on PATH, SwiftPM compiles Package.swift fine and then cannot run the
rem result, reporting only "Missing or empty JSON output from manifest
rem compilation" -- which says nothing about the actual cause.
for /d %%R in ("%LOCALAPPDATA%\Programs\Swift\Runtimes\*") do (
  if exist "%%R\usr\bin\swiftCore.dll" set "PATH=%%R\usr\bin;%PATH%"
)

rem Point the compiler at the Windows Swift SDK explicitly. The toolchain can
rem usually find it, but when it cannot the error is the unhelpful
rem "unable to load standard library", so it is worth being explicit.
for /d %%V in ("%LOCALAPPDATA%\Programs\Swift\Platforms\*") do (
  if exist "%%V\Windows.platform\Developer\SDKs\Windows.sdk" (
    set "SDKROOT=%%V\Windows.platform\Developer\SDKs\Windows.sdk"
  )
)

%*
exit /b %errorlevel%
