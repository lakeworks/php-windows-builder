function Invoke-PhpBuild {
    <#
    .SYNOPSIS
        Build PHP.
    .PARAMETER PhpVersion
        PHP Version
    .PARAMETER Arch
        PHP Architecture
    .PARAMETER Ts
        PHP Build Type
    #>
    [OutputType()]
    param (
        [Parameter(Mandatory = $false, Position=0, HelpMessage='PHP Version')]
        [string] $PhpVersion = '',
        [Parameter(Mandatory = $true, Position=1, HelpMessage='PHP Architecture')]
        [ValidateNotNull()]
        [ValidateSet('x86', 'x64')]
        [string] $Arch,
        [Parameter(Mandatory = $true, Position=2, HelpMessage='PHP Build Type')]
        [ValidateNotNull()]
        [ValidateSet('nts', 'ts')]
        [string] $Ts,
        [Parameter(Mandatory = $false, HelpMessage='Path to optimized deps overlay (e.g. D:\phpbuild8\deps-install\vs16\x64)')]
        [string] $DepsOverlay = '',
        [Parameter(Mandatory = $false, HelpMessage='CPU architecture for compiler optimization (e.g. AVX2, AVX512)')]
        [ValidateSet('', 'SSE2', 'AVX', 'AVX2', 'AVX512')]
        [string] $CpuArch = '',
        [Parameter(Mandatory = $false, HelpMessage='Skip PGO (Profile-Guided Optimization) for faster builds')]
        [switch] $NoPgo,
        [Parameter(Mandatory = $false, HelpMessage='Path to additional PGO training PHP script (run after SDK training, before profile merge)')]
        [string] $PgoTrainingScript = '',
        [Parameter(Mandatory = $false, HelpMessage='Extra configure.js options (e.g. "--without-pdo-firebird")')]
        [string[]] $ConfigureOptions = @()
    )
    begin {
    }
    process {
        Set-NetSecurityProtocolType
        $fetchSrc = $True
        if($null -eq $PhpVersion -or $PhpVersion -eq '') {
            $fetchSrc = $False
            $PhpVersion = Get-SourcePhpVersion
        }
        $VsConfig = (Get-VsVersion -PhpVersion $PhpVersion)
        if($null -eq $VsConfig.vs) {
            throw "PHP version $PhpVersion is not supported."
        }

        $currentDirectory = (Get-Location).Path

        $tempDirectory = [System.IO.Path]::GetTempPath()

        $buildDirectory = [System.IO.Path]::Combine($tempDirectory, ("php-" + [System.Guid]::NewGuid().ToString()))

        New-Item "$buildDirectory" -ItemType "directory" -Force > $null 2>&1

        Set-Location "$buildDirectory"

        Add-BuildRequirements -PhpVersion $PhpVersion -Arch $Arch -FetchSrc:$fetchSrc

        # Pre-seed composer.phar from cache so the SDK doesn't download it from getcomposer.org.
        # composer.phar lives in the SDK's pgo/work/tools/ dir (returned by PGO Config::getToolsDir()).
        # TEMP is swept by Level 1 cleanup between builds, so without caching every build re-downloads it.
        $cacheBase = if ($env:PHPBUILD_ROOT) { "$env:PHPBUILD_ROOT\deps-src" } else { "D:\phpbuild8\deps-src" }
        $composerCache  = "$cacheBase\composer.phar"
        $composerTarget = "$buildDirectory\php-sdk\pgo\work\tools\composer.phar"
        if (Test-Path $composerCache) {
            New-Item (Split-Path $composerTarget) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            Copy-Item $composerCache $composerTarget -ErrorAction SilentlyContinue
            Write-Host "[CACHE] Pre-seeded composer.phar from $composerCache" -ForegroundColor Green
        }

        Copy-Item -Path "$PSScriptRoot\..\config" -Destination . -Recurse
        Copy-Item -Path "$PSScriptRoot\..\runner" -Destination . -Recurse
        $buildPath = "$buildDirectory\config\$($VsConfig.vs)\$Arch\php-$PhpVersion"
        $sourcePath = "$buildDirectory\php-$PhpVersion-src"
        if(-not($fetchSrc)) {
            $sourcePath = $currentDirectory
        }
        if ($fetchSrc) {
            Move-Item $sourcePath $buildPath
        } else {
            # Copy local source to preserve the original directory (e.g. git worktree)
            # Use robocopy for efficiency; exclude .git metadata
            New-Item $buildPath -ItemType Directory -Force | Out-Null
            & robocopy $sourcePath $buildPath /E /NFL /NDL /NJH /NJS /XD .git | Out-Null
        }
        Set-Location "$buildPath"
        New-Item "..\obj" -ItemType "directory" > $null 2>&1
        Copy-Item "..\config.$Ts.bat"

        if($null -ne $env:LIBS_BUILD_RUNS) {
            Add-PhpDeps -PhpVersion $PhpVersion -VsVersion $VsConfig.vs -Arch $Arch -Destination "$buildPath\..\deps"
            $task = "$buildDirectory\runner\task-$Ts.bat"
        } else {
            $task = "$buildDirectory\runner\task-$Ts-with-deps.bat"
        }

        # Patch phpsdk_setshell.bat to use SDK 22621 when available (avoids UCRT CFG
        # incompatibility between SDK 26100 and v142 toolset on Windows Server 2025)
        $sdk22621 = "C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0"
        $setshellBat = "$buildDirectory\php-sdk\bin\phpsdk_setshell.bat"
        if ((Test-Path $sdk22621) -and (Test-Path $setshellBat)) {
            $batContent = Get-Content $setshellBat -Raw
            # Append -winsdk=10.0.22621.0 to the vcvarsall.bat calls that use -vcvars_ver
            $batContent = $batContent.Replace(
                '-vcvars_ver=%TOOLSET%',
                '-vcvars_ver=%TOOLSET% 10.0.22621.0'
            )
            Set-Content -Path $setshellBat -Value $batContent -NoNewline
        }

        # Allow the SDK's bundled PHP outbound access (deps download + PGO training)
        $sdkPhpExe = "$buildDirectory\php-sdk\bin\php\php.exe"
        $fwRuleName = "BuildPhp SDK PHP"
        $fwRule = $null
        # Remove stale rules from previous builds (display name can have duplicates
        # pointing to old GUID-based temp paths that no longer exist)
        Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        if (Test-Path $sdkPhpExe) {
            try {
                $fwRule = New-NetFirewallRule -DisplayName $fwRuleName `
                    -Direction Outbound -Action Allow `
                    -Program $sdkPhpExe -Protocol TCP `
                    -Enabled True -ErrorAction Stop
                Write-Host "[FW] Created outbound allow rule for SDK PHP: $sdkPhpExe" -ForegroundColor Green
            } catch {
                Write-Warning "[FW] Failed to create firewall rule for SDK PHP: $_"
                Write-Warning "[FW] Network access to downloads.php.net may fail (deps download)"
            }
        } else {
            Write-Warning "[FW] SDK php.exe not found at $sdkPhpExe"
        }

        # Pre-seed SDK known_branches.txt cache so phpsdk_deps.bat works even if
        # the HTTP fetch to downloads.php.net fails (e.g. firewall blocks it).
        # The cache key is md5(deps_path) where deps_path = parent_of_cwd\deps.
        # CWD during phpsdk_deps.bat = $buildPath, so deps_path = config\{vs}\{arch}\deps.
        $depsPathForCache = "$buildDirectory\config\$($VsConfig.vs)\$Arch\deps"
        $sdkCacheDir = "$buildDirectory\php-sdk\.cache"
        New-Item $sdkCacheDir -ItemType Directory -Force | Out-Null
        $md5Provider = [System.Security.Cryptography.MD5]::Create()
        $hashBytes = $md5Provider.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($depsPathForCache))
        $hashHex = ($hashBytes | ForEach-Object { $_.ToString("x2") }) -join ""
        $md5Provider.Dispose()
        $knownBranchesJson = @'
{
    "8.3": {
        "vs16": [
            {"arch": "x64", "stability": "stable"},
            {"arch": "x64", "stability": "staging"},
            {"arch": "x86", "stability": "stable"},
            {"arch": "x86", "stability": "staging"}
        ]
    },
    "8.4": {
        "vs17": [
            {"arch": "x64", "stability": "stable"},
            {"arch": "x64", "stability": "staging"},
            {"arch": "x86", "stability": "stable"},
            {"arch": "x86", "stability": "staging"}
        ]
    },
    "8.5": {
        "vs17": [
            {"arch": "x64", "stability": "stable"},
            {"arch": "x64", "stability": "staging"},
            {"arch": "x86", "stability": "stable"},
            {"arch": "x86", "stability": "staging"}
        ]
    },
    "8.6": {
        "vs17": [
            {"arch": "x64", "stability": "stable"},
            {"arch": "x64", "stability": "staging"},
            {"arch": "x86", "stability": "stable"},
            {"arch": "x86", "stability": "staging"}
        ]
    },
    "master": {
        "vs17": [
            {"arch": "x64", "stability": "stable"},
            {"arch": "x64", "stability": "staging"},
            {"arch": "x86", "stability": "stable"},
            {"arch": "x86", "stability": "staging"}
        ]
    }
}
'@
        $cacheFilePath = Join-Path $sdkCacheDir "$hashHex.known_branches.txt"
        Set-Content -Path $cacheFilePath -Value $knownBranchesJson -NoNewline -Encoding UTF8
        Write-Host "[DEPS] Pre-seeded SDK known_branches cache (key=$hashHex)" -ForegroundColor Green

        # ── Activate PGO training cases ──
        # The PHP SDK ships with all cases except pgo01org marked inactive.
        # WordPress and Symfony provide realistic workloads that exercise far more
        # of PHP's codebase, producing better PGO profiles (more "hot" functions
        # compiled for speed instead of size).
        if (-not $NoPgo) {
            $pgoCasesDir = "$buildDirectory\php-sdk\pgo\cases"
            if (Test-Path $pgoCasesDir) {
                # Activate WordPress training case
                $wpInactive = Join-Path $pgoCasesDir "wordpress\inactive"
                if (Test-Path $wpInactive) {
                    Remove-Item $wpInactive -Force
                    Write-Host '[PGO] Activated training case: wordpress' -ForegroundColor Green
                }

                # Activate Symfony demo training case
                $sfInactive = Join-Path $pgoCasesDir "symfony_demo\inactive"
                if (Test-Path $sfInactive) {
                    Remove-Item $sfInactive -Force
                    Write-Host '[PGO] Activated training case: symfony_demo' -ForegroundColor Green
                }

                # Update wp-cli to PHP 8.3+ compatible version (stock v2.4.0 is from 2019, PHP 7 only)
                $wpJson = Join-Path $pgoCasesDir "wordpress\phpsdk_pgo.json"
                if (Test-Path $wpJson) {
                    $wpJsonContent = Get-Content $wpJson -Raw
                    if ($wpJsonContent -match 'wp-cli-2\.4\.0') {
                        $wpJsonContent = $wpJsonContent.Replace(
                            'https://github.com/wp-cli/wp-cli/releases/download/v2.4.0/wp-cli-2.4.0.phar',
                            'https://github.com/wp-cli/wp-cli/releases/download/v2.11.0/wp-cli-2.11.0.phar'
                        )
                        Set-Content -Path $wpJson -Value $wpJsonContent -NoNewline
                        Write-Host '[PGO] Updated wp-cli v2.4.0 -> v2.11.0 (PHP 8.3+ compat)' -ForegroundColor Green
                    }
                }

                # Create pwgen.cmd wrapper (WordPress handler calls shell_exec("pwgen -1 -s 8")
                # for random password generation — pwgen is a Unix tool not available on Windows)
                $sdkBin = "$buildDirectory\php-sdk\bin"
                $pwgenCmd = Join-Path $sdkBin "pwgen.cmd"
                if (-not (Test-Path $pwgenCmd)) {
                    @"
@echo off
rem pwgen replacement for Windows (WordPress PGO training case)
rem Generates a random alphanumeric password. Usage: pwgen [-1] [-s] [length]
set "LEN=8"
for %%a in (%*) do (
    echo %%a| findstr /r "^[0-9][0-9]*$" >nul 2>&1 && set "LEN=%%a"
)
powershell -NoProfile -Command "-join((48..57)+(65..90)+(97..122)|Get-Random -Count %LEN%|ForEach-Object{[char]`$_})"
"@ | Set-Content -Path $pwgenCmd -Encoding ASCII
                    Write-Host '[PGO] Created pwgen.cmd wrapper for WordPress setup' -ForegroundColor Green
                }

                # Patch Symfony demo handler: old symfony.phar is discontinued (403 from CDN)
                # Replace with Composer create-project and fix docroot (web/ -> public/)
                # Note: using .Replace() (not -replace) to avoid $ being treated as regex backrefs
                $sfHandler = Join-Path $pgoCasesDir "symfony_demo\TrainingCaseHandler.php"
                if (Test-Path $sfHandler) {
                    $sfContent = Get-Content $sfHandler -Raw
                    if ($sfContent -match 'symfony\.phar') {
                        # 1. setupDist: replace symfony.phar demo with composer create-project
                        #    + add explicit DB setup and fixture loading (not included in auto-scripts)
                        $sfCreateProject = @'
$composer = $this->conf->getToolsDir() . DIRECTORY_SEPARATOR . "composer.phar";
            $php->exec($composer . " create-project symfony/symfony-demo " . $this->base . " --no-interaction");
            /* Symfony demo ships with pre-built SQLite DB (tables + fixtures included).
               Run schema:update (idempotent) and cache:warmup. Fixtures use dev env
               since DoctrineFixturesBundle is only registered for dev/test. */
            $consoleBin = $this->base . DIRECTORY_SEPARATOR . "bin" . DIRECTORY_SEPARATOR . "console";
            try { $php->exec($consoleBin . " doctrine:schema:update --force --env=prod --no-interaction"); } catch (\Throwable $e) { echo "Schema update: " . $e->getMessage() . "\n"; }
            try { $php->exec($consoleBin . " doctrine:fixtures:load --env=dev --no-interaction --append"); } catch (\Throwable $e) { echo "Fixtures: " . $e->getMessage() . "\n"; }
            try { $php->exec($consoleBin . " cache:warmup --env=prod"); } catch (\Throwable $e) { echo "Cache warmup: " . $e->getMessage() . "\n"; }
            echo "Symfony demo: setup complete.\n";
'@
                        $sfContent = $sfContent.Replace(
                            '$php->exec($this->getToolFn() . " demo " . $this->base);',
                            $sfCreateProject
                        )
                        # 2. Fix docroot: modern symfony-demo uses public/ not web/
                        $sfContent = $sfContent.Replace(
                            'DIRECTORY_SEPARATOR . "web"',
                            'DIRECTORY_SEPARATOR . "public"'
                        )
                        # 3. prepareInit: skip downloading defunct symfony.phar (composer already available)
                        $sfContent = $sfContent.Replace(
                            '$pw->fetch($url, $this->getToolFn(), $force);',
                            '/* symfony.phar discontinued - using composer create-project instead */'
                        )
                        Set-Content -Path $sfHandler -Value $sfContent -NoNewline
                        Write-Host '[PGO] Patched Symfony demo: composer create-project + public/ docroot' -ForegroundColor Green
                    }
                }

                # Patch WordPress handler: add ZipArchive fallback for PharData failure
                # wp-cli's core download uses PharData to extract tar.gz, which fails
                # silently on the PGO-instrumented PHP. If extraction failed (no version.php),
                # download wordpress-latest.zip and extract with ZipArchive instead.
                $wpHandler = Join-Path $pgoCasesDir "wordpress\TrainingCaseHandler.php"
                if (Test-Path $wpHandler) {
                    $wpContent = Get-Content $wpHandler -Raw
                    if ($wpContent -match 'core download' -and $wpContent -notmatch 'zip fallback') {
                        $wpZipFallback = @'
/* Verify extraction (PharData fails silently with PGO-instrumented PHP) */
if (!file_exists($this->base . DIRECTORY_SEPARATOR . "wp-includes" . DIRECTORY_SEPARATOR . "version.php")) {
    echo "WARNING: PharData extraction failed, trying zip fallback...\n";
    $zipUrl = "https://wordpress.org/latest.zip";
    $zipFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . "wordpress-latest.zip";
    @copy($zipUrl, $zipFile);
    if (file_exists($zipFile)) {
        $zip = new \ZipArchive();
        if ($zip->open($zipFile) === true) {
            $zip->extractTo(dirname($this->base));
            $zip->close();
            echo "WordPress zip extraction successful.\n";
        }
        @unlink($zipFile);
    }
    if (!file_exists($this->base . DIRECTORY_SEPARATOR . "wp-includes" . DIRECTORY_SEPARATOR . "version.php")) {
        echo "ERROR: WordPress installation failed. Check PGO ini extensions.\n";
    }
}
unset($php);
'@
                        $wpContent = $wpContent.Replace('unset($php);', $wpZipFallback)

                        # Also add stream-wrapper fallback for wordpress-importer plugin
                        # wp-cli's cURL fails with our custom libcurl+OpenSSL (error 28 timeout),
                        # but PHP stream wrappers use WinHTTP and work fine.
                        # Note: exec() returns int (exit code), does NOT throw exceptions.
                        $wpImporterFallback = @'
$_ret = $php->exec($this->getToolFn() . " plugin install wordpress-importer --activate --allow-root $cmd_path_arg", NULL, $env);
		if ($_ret !== 0) {
			echo "wp-cli plugin install failed (exit=$_ret), trying stream-wrapper fallback...\n";
			$pluginUrl = "https://downloads.wordpress.org/plugin/wordpress-importer.latest-stable.zip";
			$pluginZip = sys_get_temp_dir() . DIRECTORY_SEPARATOR . "wordpress-importer.zip";
			@copy($pluginUrl, $pluginZip);
			if (file_exists($pluginZip)) {
				$zip = new \ZipArchive();
				if ($zip->open($pluginZip) === true) {
					$zip->extractTo($this->base . DIRECTORY_SEPARATOR . "wp-content" . DIRECTORY_SEPARATOR . "plugins");
					$zip->close();
					echo "WordPress importer plugin installed via fallback.\n";
					$php->exec($this->getToolFn() . " plugin activate wordpress-importer --allow-root $cmd_path_arg", NULL, $env);
				}
				@unlink($pluginZip);
			}
		}
'@
                        $wpContent = $wpContent.Replace(
                            ('$cmd = $this->getToolFn() . " plugin install wordpress-importer' +
                             ' --activate --allow-root $cmd_path_arg";' + "`n" +
                             '		$php->exec($cmd, NULL, $env);'),
                            $wpImporterFallback
                        )

                        Set-Content -Path $wpHandler -Value $wpContent -NoNewline
                        Write-Host '[PGO] Patched WordPress: added zip extraction fallback for PharData failure' -ForegroundColor Green
                    }
                }

                # Patch WordPress NGINX config: add try_files for pretty permalinks
                # Without this, NGINX returns 403 for all non-file URLs (WordPress needs
                # all requests routed through index.php)
                $wpNginx = Join-Path $pgoCasesDir "wordpress\nginx.partial.conf"
                if (Test-Path $wpNginx) {
                    $wpNginxContent = Get-Content $wpNginx -Raw
                    if ($wpNginxContent -notmatch 'try_files') {
                        $wpNginxContent = $wpNginxContent.Replace(
                            'location ~ \.php$ {',
                            ("location / {`n" +
                             "            try_files `$uri `$uri/ /index.php`$is_args`$args;`n" +
                             "        }`n`n" +
                             "        location ~ \.php`$ {")
                        )
                        Set-Content -Path $wpNginx -Value $wpNginxContent -NoNewline
                        Write-Host '[PGO] Patched WordPress NGINX: added try_files for permalinks' -ForegroundColor Green
                    }
                }

                # Patch Symfony demo NGINX config: use index.php instead of app.php
                # Modern Symfony Demo (5.x/6.x/7.x) uses public/index.php, not web/app.php
                $sfNginx = Join-Path $pgoCasesDir "symfony_demo\nginx.partial.conf"
                if (Test-Path $sfNginx) {
                    $sfNginxContent = Get-Content $sfNginx -Raw
                    if ($sfNginxContent -match 'app\.php') {
                        # Replace both literal 'app.php' (in try_files) and regex-escaped 'app\.php' (in location block)
                        $sfNginxContent = $sfNginxContent.Replace('app.php', 'index.php').Replace('app\.php', 'index\.php')
                        Set-Content -Path $sfNginx -Value $sfNginxContent -NoNewline
                        Write-Host '[PGO] Patched Symfony NGINX: app.php -> index.php (incl. regex)' -ForegroundColor Green
                    }
                }

                # Patch PGO.php: switch pgosweep/pgomgr from shell_exec() to passthru()
                # shell_exec() silently discards all output and errors, making PGO failures invisible.
                # passthru() shows output and we add return code checking for diagnostics.
                $pgoToolPhp = Join-Path $buildDirectory "php-sdk\lib\php\libsdk\SDK\Build\PGO\Tool\PGO.php"
                if (Test-Path $pgoToolPhp) {
                    $pgoContent = Get-Content $pgoToolPhp -Raw
                    if ($pgoContent -match 'shell_exec\("pgosweep') {
                        $pgoContent = $pgoContent.Replace(
                            'shell_exec("pgosweep $base $pgc");',
                            ('$ret = 0;' + "`n" +
                             '			passthru("pgosweep \"$base\" \"$pgc\"", $ret);' + "`n" +
                             '			if ($ret !== 0) { echo "  pgosweep failed (exit=$ret) for " . basename($base) . "\n"; }')
                        )
                        $pgoContent = $pgoContent.Replace(
                            'shell_exec("pgomgr /merge:1000 $pgc $pgd");',
                            ('passthru("pgomgr /merge:1000 \"$pgc\" \"$pgd\"", $ret);' + "`n" +
                             '				if ($ret !== 0) { echo "  pgomgr merge failed (exit=$ret) for " . basename($base) . "\n"; }')
                        )
                        $pgoContent = $pgoContent.Replace(
                            'shell_exec("pgomgr /clear $pgd");',
                            'passthru("pgomgr /clear \"$pgd\"");'
                        )
                        Set-Content -Path $pgoToolPhp -Value $pgoContent -NoNewline
                        Write-Host '[PGO] Patched pgosweep/pgomgr: shell_exec -> passthru (visible errors)' -ForegroundColor Green
                    }
                }

                # Patch PGO ini templates: add curl.cainfo for PGI php-cgi.exe
                # The SDK CLI php.exe gets curl.cainfo via -d flag in PHP.php::exec(),
                # but the PGI php-cgi.exe (FCGI.php::up()) uses bare ini without it.
                # Without curl.cainfo, libcurl+OpenSSL can't verify SSL → cURL error 28.
                $certPem = Join-Path $buildDirectory "php-sdk\msys2\usr\ssl\cert.pem"
                if (Test-Path $certPem) {
                    $pgoTplDir = Join-Path $buildDirectory "php-sdk\pgo\tpl\php"
                    Get-ChildItem $pgoTplDir -Filter "*.ini" -ErrorAction SilentlyContinue | ForEach-Object {
                        $iniContent = Get-Content $_.FullName -Raw
                        if ($iniContent -notmatch 'curl\.cainfo') {
                            $certPemEscaped = $certPem.Replace('\', '\\')
                            $iniContent += "`ncurl.cainfo=`"$certPemEscaped`"`nopenssl.cafile=`"$certPemEscaped`"`n"
                            Set-Content -Path $_.FullName -Value $iniContent -NoNewline
                        }
                    }
                    Write-Host ('[PGO] Patched PGO ini templates: curl.cainfo={0}' -f $certPem) -ForegroundColor Green
                }
            }
        }

        # Inject CPU architecture optimization: adds /arch: flag to ALL cl.exe invocations
        # via the CL environment variable (standard MSVC global flags mechanism)
        $taskContent = Get-Content $task -Raw
        if ($CpuArch) {
            # MSVC /arch:AVX512 defines __AVX512F__, __AVX2__, __AVX__ but NOT __SSSE3__,
            # __SSE4_1__, __SSE4_2__. PHP's zend_portability.h uses these to select SIMD
            # dispatch strategy (native vs runtime). Without them, SSSE3 code uses function
            # pointer dispatch while AVX2 is native, causing linker errors in base64_intrin.
            # Fix: explicitly define the SSE macros that AVX-512 implies.
            $archFlags = '/arch:{0}' -f $CpuArch
            if ($CpuArch -eq 'AVX512') {
                $archFlags += ' /D__SSSE3__ /D__SSE4_1__ /D__SSE4_2__'
            } elseif ($CpuArch -eq 'AVX2') {
                $archFlags += ' /D__SSSE3__ /D__SSE4_1__ /D__SSE4_2__'
            }
            $cpuPreamble = @(
                ('set "CL=%CL% {0}"' -f $archFlags)
                ('echo [CPU] Compiler targeting {0} 2>&1' -f $archFlags)
            ) -join "`r`n"
            $taskContent = $cpuPreamble + "`r`n" + $taskContent
            Write-Host ('[CPU] Targeting {0} for all compilation' -f $archFlags) -ForegroundColor Cyan
        }

        # Inject extra configure options (e.g. --without-pdo-firebird)
        if ($ConfigureOptions.Count -gt 0) {
            $configBat = "config.$Ts.bat"
            $configContent = Get-Content $configBat -Raw
            $extraArgs = ($ConfigureOptions | ForEach-Object { "`"$_`"" }) -join ' '
            $configContent = $configContent.Replace(' %*', " $extraArgs %*")
            Set-Content -Path $configBat -Value $configContent -NoNewline
            Write-Host "[CONFIG] Extra options: $($ConfigureOptions -join ', ')" -ForegroundColor Cyan
        }

        # Strip PGO for faster builds when -NoPgo is set
        if ($NoPgo) {
            # Remove --enable-pgi from config.bat so the build uses normal /O2
            # optimization instead of PGO instrumentation (/GENPROFILE)
            $configBat = "config.$Ts.bat"
            $configContent = Get-Content $configBat -Raw
            $configContent = $configContent.Replace('"--enable-pgi" ', '')
            Set-Content -Path $configBat -Value $configContent -NoNewline

            # Replace PGO flow (nmake -> PGO train -> PGO reconfig -> nmake snap)
            # with simple: nmake && nmake snap
            $noPgoTask = @(
                'nmake 2>&1'
                'if errorlevel 1 exit 4'
                'nmake snap 2>&1'
                'if errorlevel 1 exit 5'
            ) -join "`r`n"
            $taskContent = $taskContent -replace '(?s)nmake 2>&1.*$', $noPgoTask
            Write-Host '[PGO] Disabled - building without Profile-Guided Optimization' -ForegroundColor Yellow
        }

        # Inject optimized deps overlay: replaces stock deps with AVX-512 optimized builds
        if ($DepsOverlay -and (Test-Path $DepsOverlay)) {
            $overlayLines = @(
                ('echo [DEPS] Overlaying optimized deps from {0} 2>&1' -f $DepsOverlay)
                ('robocopy "{0}" ..\deps /E /NFL /NDL /NJH /NJS /NP /IS 2>&1' -f $DepsOverlay)
                'if errorlevel 8 exit 1'
                'call buildconf.bat 2>&1'
            ) -join "`r`n"
            $taskContent = $taskContent.Replace('call buildconf.bat 2>&1', $overlayLines)
            Write-Host ('[DEPS] Overlay injection: {0} -> ..\deps' -f $DepsOverlay) -ForegroundColor Cyan
        }

        # Inject PGO firewall rules (only when PGO is enabled)
        if (-not $NoPgo) {
        # Allow newly-built php.exe/php-cgi.exe outbound access for PGO training
        # (downloads during init + HTTP requests to local NGINX on high ports)
        # Use PowerShell-computed path (Makefile parsing had trailing whitespace issues)
        $pgiDir = "$buildDirectory\config\$($VsConfig.vs)\$Arch\obj\Release"
        $pgoFwAdd = @(
            'rem [PGO] Add temporary firewall rules for PGO-instrumented PHP binaries'
            ('set "PGI_DIR={0}"' -f $pgiDir)
            'echo [FW] PGI build dir: %PGI_DIR% 2>&1'
            'if exist "%PGI_DIR%\php.exe" ('
            '    netsh advfirewall firewall add rule name="BuildPhp PGO php.exe" dir=out action=allow program="%PGI_DIR%\php.exe" protocol=tcp enable=yes 2>&1'
            '    echo [FW] Created outbound rule for PGI php.exe 2>&1'
            ') else ('
            '    echo [FW] WARNING: php.exe not found at %PGI_DIR% 2>&1'
            ')'
            'if exist "%PGI_DIR%\php-cgi.exe" ('
            '    netsh advfirewall firewall add rule name="BuildPhp PGO php-cgi.exe" dir=out action=allow program="%PGI_DIR%\php-cgi.exe" protocol=tcp enable=yes 2>&1'
            '    echo [FW] Created outbound rule for PGI php-cgi.exe 2>&1'
            ') else ('
            '    echo [FW] WARNING: php-cgi.exe not found at %PGI_DIR% 2>&1'
            ')'
        ) -join "`r`n"
        $pgoFwRemove = @(
            'rem [PGO] Remove temporary firewall rules'
            'netsh advfirewall firewall delete rule name="BuildPhp PGO php.exe" >nul 2>&1'
            'netsh advfirewall firewall delete rule name="BuildPhp PGO php-cgi.exe" >nul 2>&1'
        ) -join "`r`n"

        # Insert additional PGO training script (zlib-ng, libxml2, Oniguruma, PCRE2, Zend VM)
        if ($PgoTrainingScript -and (Test-Path $PgoTrainingScript)) {
            $pgiPhpExe = "$pgiDir\php.exe"
            # Must explicitly load shared extensions — PGI php.exe has no php.ini
            # GD, sodium, pdo_sqlite omitted: GD libs drop /GL (always /Ox), others fail to load
            $extFlags = @(
                '-d extension_dir="{0}"' -f $pgiDir
                '-d extension=mbstring'
                '-d extension=simplexml'
                '-d extension=dom'
            ) -join ' '
            $gdTraining = @(
                'echo [PGO] Running additional training: {0} 2>&1' -f (Split-Path $PgoTrainingScript -Leaf)
                '"{0}" {1} "{2}" 2>&1' -f $pgiPhpExe, $extFlags, $PgoTrainingScript
                'echo [PGO] Additional training complete 2>&1'
            ) -join "`r`n"
            $taskContent = $taskContent.Replace(
                'nmake clean-pgo 2>&1',
                $gdTraining + "`r`n" + 'nmake clean-pgo 2>&1'
            )
            Write-Host ('[PGO] Injected additional training: {0}' -f $PgoTrainingScript) -ForegroundColor Green
        }

        # Insert firewall add after first nmake, before phpsdk_pgo --init
        $pgoInitReplacement = $pgoFwAdd + "`r`n" + 'call phpsdk_pgo --init 2>&1'
        $taskContent = $taskContent.Replace('call phpsdk_pgo --init 2>&1', $pgoInitReplacement)
        # Insert firewall remove after PGO training, before nmake clean-pgo
        $pgoCleanReplacement = $pgoFwRemove + "`r`n" + 'nmake clean-pgo 2>&1'
        $taskContent = $taskContent.Replace('nmake clean-pgo 2>&1', $pgoCleanReplacement)
        } # end if (-not $NoPgo)
        Set-Content -Path $task -Value $taskContent -NoNewline

        # Disable IPv6 during PGO training if no routable IPv6 exists.
        # libcurl tries IPv6 first (AAAA records), but without routable IPv6 the
        # connection hangs for 10s per request before falling back to IPv4.
        $ipv6DisabledAdapters = @()
        if (-not $NoPgo) {
            $hasRoutableIPv6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike 'fe80::*' -and $_.IPAddress -ne '::1' }
            if (-not $hasRoutableIPv6) {
                $ipv6DisabledAdapters = @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue |
                    Where-Object { $_.Enabled } | ForEach-Object {
                        Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
                        $_.Name  # capture adapter name for selective restore
                    })
                if ($ipv6DisabledAdapters.Count -gt 0) {
                    Write-Host "[PGO] Disabled IPv6 on $($ipv6DisabledAdapters.Count) adapter(s) (no routable IPv6, prevents cURL timeout)" -ForegroundColor Green
                }
            }
        }

        try {
            & "$buildDirectory\php-sdk\phpsdk-starter.bat" -c $VsConfig.vs -a $Arch -s $VsConfig.toolset -t $task
            if (-not $?) {
                throw "build failed with errorlevel $LastExitCode"
            }
        } finally {
            # Always clean up SDK PHP firewall rule (by display name, not just $fwRule reference)
            Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue |
                Remove-NetFirewallRule -ErrorAction SilentlyContinue
            # Safety cleanup: remove PGO firewall rules in case bat exited early
            Remove-NetFirewallRule -DisplayName "BuildPhp PGO php.exe" -ErrorAction SilentlyContinue
            Remove-NetFirewallRule -DisplayName "BuildPhp PGO php-cgi.exe" -ErrorAction SilentlyContinue
            # Re-enable IPv6 only on adapters we disabled (not all disabled adapters)
            if ($ipv6DisabledAdapters.Count -gt 0) {
                foreach ($adapterName in $ipv6DisabledAdapters) {
                    Enable-NetAdapterBinding -Name $adapterName -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
                }
            }
            # Clean stale php-sdk temp entries from User PATH registry
            # (phpsdk_setshell.bat persists them via setx, causing accumulation across builds)
            $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
            if ($userPath) {
                $cleaned = ($userPath -split ';' | Where-Object { $_ -and $_ -notmatch '\\Temp\\.*\\php-' }) -join ';'
                if ($cleaned -ne $userPath) {
                    $removedCount = ($userPath -split ';' | Where-Object { $_ -match '\\Temp\\.*\\php-' }).Count
                    [Environment]::SetEnvironmentVariable("PATH", $cleaned, "User")
                    Write-Host "[PATH] Cleaned $removedCount stale php-sdk temp entries from User PATH registry" -ForegroundColor Green
                }
            }
            # Cache composer.phar to D: so next build can pre-seed it without hitting getcomposer.org
            if ((Test-Path $composerTarget) -and -not (Test-Path $composerCache)) {
                Copy-Item $composerTarget $composerCache -ErrorAction SilentlyContinue
                Write-Host "[CACHE] Saved composer.phar to $composerCache" -ForegroundColor Green
            }
        }

        $artifacts = if ($Ts -eq "ts") {"..\obj\Release_TS\php-*.zip"} else {"..\obj\Release\php-*.zip"}
        New-Item "$currentDirectory\artifacts" -ItemType "directory" -Force > $null 2>&1
        xcopy $artifacts "$currentDirectory\artifacts\*"
        if ($fetchSrc -and (Test-Path "$buildDirectory\php-$PhpVersion-src.zip")) {
            Move-Item "$buildDirectory\php-$PhpVersion-src.zip" "$currentDirectory\artifacts\"
        }

        Set-Location "$currentDirectory"
    }
    end {
    }
}