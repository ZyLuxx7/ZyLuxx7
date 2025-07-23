# install_vm_client.ps1
# Dieses Skript wird auf den Windows 11 VMs ausgeführt.
# Es automatisiert die Installation von Python, den benötigten Bibliotheken,
# lädt den VM Control Client von GitHub herunter und richtet den automatischen Start ein.
# Das Skript ist darauf ausgelegt, Probleme selbstständig zu beheben, wo möglich.

# --- Konfiguration (BITTE ÜBERPRÜFEN / ANPASSEN) ---
# Dies ist die URL zur ZIP-Datei deines GitHub-Repositories.
# MUSS die korrekte URL sein, die du von GitHub kopiert hast (z.B. aus dem "Code" -> "Download ZIP" Button).
$GitHubRepoZipUrl = "https://github.com/ZyLuxx7/ZyLuxx7/archive/refs/heads/main.zip" # <-- HIER ANPASSEN, WENN SICH DEIN REPO ÄNDERT!

# Dies ist der relative Pfad ZUM ORDNER des Clients INNERHALB des entpackten ZIP-Archives.
# Für dein Repo "ZyLuxx7/ZyLuxx7" und den Client in "test/", ist der Pfad innerhalb des ZIPs "ZyLuxx7-main/test".
$GitHubClientRelativePathInZip = "ZyLuxx7-main/test" # <-- HIER MÖGLICHERWEISE ANPASSEN!

# Der Dateiname deines Python-Client-Skripts im GitHub-Repo.
$ClientScriptName = "client.py" # <-- HIER ANPASSEN, falls dein Client anders heißt (z.B. vm_client.py)!

# --- Netzwerk-Ports (MÜSSEN MIT main_app.py und client.py ÜBEREINSTIMMEN) ---
$MulticastPort = 5007 # UDP eingehend (für Client zum Empfangen von Server-Beacons)
$ServerTcpPort = 12345 # TCP ausgehend (für Client zum Verbinden mit Server)

# --- Python- und Installationspfade ---
$PythonVersion = "3.9.13" # Empfohlene Python-Version für Stabilität
$PythonInstallerUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe"
$ClientAppDir = "C:\VMControlClient" # Zielverzeichnis auf der VM für den Client
$ClientScriptPath = Join-Path $ClientAppDir $ClientScriptName
$SchedulerTaskName = "VMControlClientAutoStart" # Name der Windows-Aufgabe für den Autostart

# --- Firewall-Regel Namen und Beschreibungen ---
$MulticastRuleName = "VMControlClient_Multicast_Inbound_UDP"
$MulticastRuleDescription = "Erlaubt eingehenden UDP-Multicast für VM Control Client Service Discovery (Port $MulticastPort)."

# --- Hilfsfunktion für Log-Ausgabe ---
function Log-Message {
    param(
        [string]$Message
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Timestamp] $Message" -ForegroundColor Cyan
}

# --- Funktionen für die Installation ---

function Test-PythonInstallation {
    Log-Message "Überprüfe Python-Installation..."
    try {
        $pythonPath = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
        if ($pythonPath) {
            $pythonVersionOutput = (python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')" -ErrorAction Stop)
            Log-Message "Python gefunden: $pythonPath (Version: $pythonVersionOutput)"
            return $true
        } else {
            Log-Message "Python nicht im PATH gefunden."
            return $false
        }
    } catch {
        Log-Message "Fehler beim Überprüfen der Python-Installation: $_"
        return $false
    }
}

function Install-Python {
    Log-Message "Python wird installiert..."
    $InstallerPath = Join-Path $env:TEMP "python_installer.exe"
    
    try {
        # Prüfe Internetverbindung
        Log-Message "Prüfe Internetverbindung zum Herunterladen des Python-Installers..."
        try {
            $webRequest = Invoke-WebRequest -Uri "http://www.google.com" -UseBasicParsing -ErrorAction SilentlyContinue
            if ($webRequest.StatusCode -ne 200) {
                Log-Message "WARNUNG: Keine aktive Internetverbindung oder Zugriff auf Google.com. Python-Download könnte fehlschlagen." -ForegroundColor Yellow
            } else {
                Log-Message "Internetverbindung scheint aktiv."
            }
        } catch {
            Log-Message "FEHLER: Internetverbindungstest fehlgeschlagen: $_. Python-Download könnte fehlschlagen." -ForegroundColor Red
        }

        Invoke-WebRequest -Uri $PythonInstallerUrl -OutFile $InstallerPath -ErrorAction Stop
        Log-Message "Python-Installer heruntergeladen."

        $installArgs = "/quiet InstallAllUsers=1 PrependPath=1 Include_debug_symbols=0 Include_dev_files=0 Include_test=0 Include_tcltk=0 Include_launcher=0"

        Log-Message "Starte Python-Installation... Dies kann einige Minuten dauern."
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -eq 0) {
            Log-Message "Python erfolgreich installiert."
            Remove-Item $InstallerPath -ErrorAction SilentlyContinue
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            # Nach der Installation kurz warten, um PATH-Updates zu ermöglichen
            Start-Sleep -Seconds 2
            return $true
        } else {
            Log-Message "FEHLER: Python-Installation fehlgeschlagen. Exit Code: $($process.ExitCode). Prüfen Sie das Installationslog, falls verfügbar." -ForegroundColor Red
            return $false
        }
    } catch {
        Log-Message "FEHLER: Beim Herunterladen oder Ausführen des Python-Installers: $_" -ForegroundColor Red
        return $false
    }
}

function Install-PythonDependencies {
    Log-Message "Installiere Python-Abhängigkeiten (pip)..."
    try {
        Push-Location $ClientAppDir
        
        Log-Message "Aktualisiere pip auf die neueste Version..."
        python -m pip install --upgrade pip -ErrorAction Stop
        Log-Message "pip erfolgreich aktualisiert."

        if (Test-Path (Join-Path $ClientAppDir "requirements.txt")) {
            Log-Message "requirements.txt gefunden. Installiere Abhängigkeiten daraus."
            python -m pip install -r requirements.txt -ErrorAction Stop
        } else {
            Log-Message "WARNUNG: requirements.txt nicht gefunden. Installiere Standard-Abhängigkeiten (Pillow, pynput) als Fallback." -ForegroundColor Yellow
            python -m pip install "Pillow" "pynput" -ErrorAction Stop
        }
        Pop-Location
        Log-Message "Python-Abhängigkeiten erfolgreich installiert."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Installieren von Python-Abhängigkeiten: $_" -ForegroundColor Red
        return $false
    }
}

function Download-AndExtractClient {
    param(
        [string]$ZipUrl,
        [string]$DestinationDir,
        [string]$RelativePathInZip,
        [string]$TargetFileName
    )
    Log-Message "Lade Client-Dateien von GitHub herunter: $ZipUrl"

    $TempZipPath = Join-Path $env:TEMP "vm_client_github_repo.zip"
    $TempExtractDir = Join-Path $env:TEMP "vm_client_extract"

    try {
        if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $TempExtractDir | Out-Null

        Log-Message "Herunterladen der ZIP-Datei gestartet..."
        Invoke-WebRequest -Uri $ZipUrl -OutFile $TempZipPath -ErrorAction Stop
        Log-Message "ZIP-Datei erfolgreich heruntergeladen nach $TempZipPath."

        Log-Message "Entpacken der ZIP-Datei gestartet..."
        Expand-Archive -Path $TempZipPath -DestinationPath $TempExtractDir -Force
        Log-Message "ZIP-Datei erfolgreich entpackt nach $TempExtractDir."

        $SourceClientFolder = Join-Path $TempExtractDir $RelativePathInZip
        
        if (-not (Test-Path $SourceClientFolder)) {
            Log-Message "FEHLER: Client-Ordner '$SourceClientFolder' NICHT im extrahierten ZIP gefunden. Überprüfen Sie \$GitHubClientRelativePathInZip!" -ForegroundColor Red
            return $false
        }

        if (Test-Path $DestinationDir) { Remove-Item $DestinationDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $DestinationDir | Out-Null

        Log-Message "Kopiere Client-Dateien von '$SourceClientFolder' nach '$DestinationDir'..."
        Copy-Item -Path (Join-Path $SourceClientFolder "*") -Destination $DestinationDir -Recurse -Force
        Log-Message "Client-Dateien erfolgreich nach '$DestinationDir' kopiert."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Herunterladen oder Entpacken des Clients von GitHub: $_" -ForegroundColor Red
        return $false
    } finally {
        if (Test-Path $TempZipPath) { Remove-Item $TempZipPath -ErrorAction SilentlyContinue }
        if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Setup-ClientAutoStart {
    Log-Message "Richte automatischen Start des Clients ein..."

    $action = New-ScheduledTaskAction -Execute "python.exe" -Argument "$ClientScriptPath" -WorkingDirectory $ClientAppDir
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -Compatibility V2.1 -Hidden
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    if (Get-ScheduledTask -TaskName $SchedulerTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $SchedulerTaskName -Confirm:$false
        Log-Message "Bestehende geplante Aufgabe '$SchedulerTaskName' entfernt."
    }

    try {
        Register-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -TaskName $SchedulerTaskName -Description "Startet den VM Control Client beim Systemstart"
        Log-Message "Geplante Aufgabe '$SchedulerTaskName' erfolgreich erstellt."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Erstellen der geplanten Aufgabe: $_" -ForegroundColor Red
        return $false
    }
}

function Configure-FirewallRule {
    param(
        [int]$Port,
        [string]$RuleName,
        [string]$RuleDescription,
        [string]$Protocol,
        [string]$Direction
    )
    Log-Message "Konfiguriere Firewall für Port $Port ($Protocol $Direction)..."

    if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
        Log-Message "Bestehende Firewall-Regel '$RuleName' gefunden und wird entfernt."
        Remove-NetFirewallRule -DisplayName $RuleName -Confirm:$false
    }

    try {
        New-NetFirewallRule -DisplayName $RuleName `
                            -Description $RuleDescription `
                            -Direction $Direction `
                            -Action Allow `
                            -Protocol $Protocol `
                            -LocalPort $Port `
                            -Profile Any
        Log-Message "Firewall-Regel '$RuleName' für Port $Port ($Protocol $Direction) erfolgreich erstellt."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Erstellen der Firewall-Regel '$RuleName': $_" -ForegroundColor Red
        return $false
    }
}

# --- Haupt-Logik des Skripts ---
Log-Message "------------------------------------------------------------------------------------------------------------------"
Log-Message "STARTE VM CLIENT INSTALLATIONSSKRIPT"
Log-Message "Dieses Skript wird den VM Control Client automatisch installieren und konfigurieren."
Log-Message "------------------------------------------------------------------------------------------------------------------"

# 1. Client-Dateien von GitHub herunterladen und im Zielverzeichnis ablegen
if (-not (Download-AndExtractClient -ZipUrl $GitHubRepoZipUrl -DestinationDir $ClientAppDir -RelativePathInZip $GitHubClientRelativePathInZip -TargetFileName $ClientScriptName)) {
    Log-Message "FATALER FEHLER: Konnte Client-Dateien von GitHub nicht herunterladen oder entpacken. Skript wird beendet." -ForegroundColor Red
    Exit 1
}

# 2. Python überprüfen/installieren, falls nötig
if (-not (Test-PythonInstallation)) {
    Log-Message "Python nicht gefunden oder falsche Version. Versuche Installation..."
    if (-not (Install-Python)) {
        Log-Message "FATALER FEHLER: Konnte Python nicht installieren. Bitte prüfen Sie Ihre Internetverbindung." -ForegroundColor Red
        Exit 1
    }
}

# 3. Python-Abhängigkeiten installieren (z.B. Pillow, pynput)
if (-not (Install-PythonDependencies)) {
    Log-Message "FATALER FEHLER: Konnte Python-Abhängigkeiten nicht installieren. Skript wird beendet." -ForegroundColor Red
    Exit 1
}

# 4. Firewall-Regel für Multicast auf der VM hinzufügen (UDP eingehend)
# Dies ist notwendig, damit der Client die "Ich bin hier"-Nachrichten des Servers empfangen kann.
if (-not (Configure-FirewallRule -Port $MulticastPort -RuleName $MulticastRuleName -RuleDescription $MulticastRuleDescription -Protocol "UDP" -Direction "Inbound")) {
    Log-Message "WARNUNG: Konnte Firewall-Regel für Multicast nicht konfigurieren. Der Client könnte Schwierigkeiten haben, den Server zu finden. Manuelle Überprüfung erforderlich." -ForegroundColor Yellow
}

# 5. Automatischen Start des Clients als geplante Aufgabe einrichten
if (-not (Setup-ClientAutoStart)) {
    Log-Message "FATALER FEHLER: Fehler beim Einrichten des automatischen Starts. Skript wird beendet." -ForegroundColor Red
    Exit 1
}

Log-Message "------------------------------------------------------------------------------------------------------------------"
Log-Message "INSTALLATION ABGESCHLOSSEN!" -ForegroundColor Green
Log-Message "Der VM Client sollte beim nächsten Neustart der VM automatisch starten und nach dem Server suchen."
Log-Message "Sie können den Client manuell starten, indem Sie 'python $ClientScriptPath' in einer PowerShell ausführen."
Log-Message "------------------------------------------------------------------------------------------------------------------"
Log-Message "WICHTIGER HINWEIS: Jetzt müssen Sie die Hauptanwendung (main_app.py) auf Ihrem HAUPT-PC starten und sicherstellen, dass:" -ForegroundColor Yellow
Log-Message "1. Sie EINGEHENDE TCP-Verbindungen auf Port $ServerTcpPort erlaubt (Firewall-Regel für main_app.py)." -ForegroundColor Yellow
Log-Message "2. Ihr Netzwerk Multicast-Verkehr auf Port $MulticastPort zulässt (standardmäßig meist ok)." -ForegroundColor Yellow
Log-Message "------------------------------------------------------------------------------------------------------------------"
