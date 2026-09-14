@echo off
REM Push this folder to GitHub, build the iPhone app on a cloud Mac, and download
REM the finished Vox.ipa into build-out\ ready for iLoader.
REM
REM Double-click it. First time on a PC? Run github-auth.bat first.
REM
REM The repository is <your GitHub username>/vox. It's created automatically the
REM first time, as a PUBLIC repo - see the note below. To use a different one, put
REM "owner/name" on the first line of github-repo.txt next to this file.
REM
REM Safe to run more than once. The window always stays open at the end.

setlocal
cd /d "%~dp0"
title Vox - push and build

where git >nul 2>nul
if errorlevel 1 goto no_tools
where gh >nul 2>nul
if errorlevel 1 goto no_tools
gh auth status >nul 2>nul
if errorlevel 1 goto not_signed_in

REM ---- which repository ------------------------------------------------
set "REPO="
if exist "github-repo.txt" set /p REPO=<github-repo.txt
if defined REPO goto have_repo
for /f "tokens=*" %%A in ('gh api user --jq .login 2^>nul') do set GHUSER=%%A
if not defined GHUSER goto not_signed_in
set "REPO=%GHUSER%/vox"
:have_repo
echo Repository: %REPO%

REM ---- create it on GitHub the first time --------------------------------
REM Public, deliberately: GitHub only gives unlimited free Actions minutes to public
REM repos, and Mac minutes (which this needs) count 10x on private ones. Vox holds no
REM secrets - the server address and any key are typed into the app, not stored here.
REM Want it private instead? Create it yourself with --private before running this.
gh repo view "%REPO%" >nul 2>nul
if not errorlevel 1 goto repo_exists
echo Creating public repository %REPO% on GitHub...
gh repo create "%REPO%" --public --description "Vox - iPhone client for a self-hosted audio.cpp server"
if errorlevel 1 goto failed
:repo_exists
>github-repo.txt echo %REPO%

REM ---- local git ----------------------------------------------------------
if exist ".git" goto have_git
echo Setting up git in this folder...
git init -q
if errorlevel 1 goto failed
:have_git
git branch -M main >nul 2>nul

git config user.name >nul 2>nul
if not errorlevel 1 goto have_identity
for /f "tokens=*" %%A in ('gh api user --jq .login 2^>nul') do set GHUSER=%%A
git config user.name "%GHUSER%"
git config user.email "%GHUSER%@users.noreply.github.com"
:have_identity

git add -A
git diff --cached --quiet
if not errorlevel 1 goto nothing_new
echo Saving changes...
git commit -q -m "Update from %COMPUTERNAME% %DATE% %TIME%"
if errorlevel 1 goto failed
goto pushing
:nothing_new
echo No local changes - pushing what's already committed.

:pushing
gh auth setup-git >nul 2>nul
git remote remove origin >nul 2>nul
git remote add origin https://github.com/%REPO%.git
if errorlevel 1 goto failed

echo.
echo Pushing...
git push --force -u origin main
if errorlevel 1 goto push_failed
echo Pushed.

echo.
choice /c YN /t 20 /d Y /m "Build the iPhone app now (Yes in 20 s)"
if errorlevel 2 goto skip_build
gh workflow run ios.yml --repo %REPO% --ref main
if errorlevel 1 goto trigger_failed

echo.
echo Build started. Waiting for it...
if not exist "%~dp0wait-for-build.ps1" goto no_waiter
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wait-for-build.ps1" -Repo "%REPO%"
echo.
pause
exit /b %errorlevel%

:no_waiter
echo Watch it at https://github.com/%REPO%/actions
echo.
pause
exit /b 0

:trigger_failed
echo Couldn't start the build - start it from the Actions tab on GitHub.
echo   https://github.com/%REPO%/actions
echo.
pause
exit /b 1

:skip_build
echo.
echo Skipped the build. Start one later with:
echo   gh workflow run ios.yml --repo %REPO%
echo ...or from https://github.com/%REPO%/actions
echo.
pause
exit /b 0

:no_tools
echo Git or GitHub CLI isn't installed on this PC yet.
echo Run github-auth.bat first - it installs both and signs you in.
echo.
pause
exit /b 1

:not_signed_in
echo This PC isn't signed in to GitHub yet.
echo Run github-auth.bat first, then run this again.
echo.
pause
exit /b 1

:push_failed
echo.
echo The push didn't work. The error above says why.
echo.
echo If it mentions authentication, credentials, or a 403, run
echo github-auth.bat once, then run this again.
echo.
pause
exit /b 1

:failed
echo.
echo That didn't work. The error above says why.
echo.
pause
exit /b 1
