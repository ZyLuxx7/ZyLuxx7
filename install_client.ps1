# install_vm_client.ps1
# Dieses Skript wird auf den Windows 11 VMs ausgeführt.
# Es automatisiert die Installation von Python, den benötigten Bibliotheken,
# lädt den VM Control Client von GitHub herunter und richtet den automatischen Start ein.

# --- Konfiguration (BITTE ÜBERPRÜFEN / ANPASSEN) ---
$GitHubRepoZipUrl = "https://github.com/ZyLuxx7/ZyLuxx7/archive/refs/heads/main.zip" # <-- HIER ANPASSEN!
$GitHubClientRelativePathInZip = "ZyLuxx7-main/test" # <-- HIER MÖGLICHERWEISE ANPASSEN!
$ClientScriptName = "client.py" # <-- HIER ANPASSEN!

# --- Netzwerk-Ports ---
$ServerTcpPort = 62345

# --- Python- und Installationspfade ---
$PythonVersion = "3.9.13"
$PythonInstallerUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe"
$ClientAppDir = "C:\VMControlClient"
$ClientScriptPath = Join-Path $ClientAppDir $ClientScriptName
$SchedulerTaskName = "VMControlClientAutoStart"

$scriptError = $false

function Log-Message {
    param([string]$Message, [string]$Color = "Cyan")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Timestamp] $Message" -ForegroundColor $Color
}

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
        Log-Message "Fehler beim Überprüfen der Python-Installation: $_" -Color Red
        return $false
    }
}

function Install-Python {
    Log-Message "Python wird installiert..."
    $InstallerPath = Join-Path $env:TEMP "python_installer.exe"
    
    try {
        Log-Message "Prüfe Internetverbindung..."
        try {
            $webRequest = Invoke-WebRequest -Uri "http://www.google.com" -UseBasicParsing -ErrorAction SilentlyContinue -TimeoutSec 10
            if ($webRequest.StatusCode -ne 200) { Log-Message "WARNUNG: Keine aktive Internetverbindung." -Color Yellow }
            else { Log-Message "Internetverbindung scheint aktiv." }
        } catch { Log-Message "FEHLER: Internetverbindungstest fehlgeschlagen: $_." -Color Red }

        Invoke-WebRequest -Uri $PythonInstallerUrl -OutFile $InstallerPath -ErrorAction Stop
        Log-Message "Python-Installer heruntergeladen."
        $installArgs = "/quiet InstallAllUsers=1 PrependPath=1 Include_debug_symbols=0 Include_dev_files=0 Include_test=0 Include_tcltk=0 Include_launcher=0"
        Log-Message "Starte Python-Installation... Dies kann einige Minuten dauern."
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -eq 0) {
            Log-Message "Python erfolgreich installiert."
            Remove-Item $InstallerPath -ErrorAction SilentlyContinue
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            Start-Sleep -Seconds 2
            return $true
        } else {
            Log-Message "FEHLER: Python-Installation fehlgeschlagen. Exit Code: $($process.ExitCode)." -Color Red
            return $false
        }
    } catch {
        Log-Message "FEHLER: Beim Herunterladen oder Ausführen des Python-Installers: $_" -Color Red
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
            Log-Message "WARNUNG: requirements.txt nicht gefunden. Installiere Standard-Abhängigkeiten (Pillow, pynput) als Fallback." -Color Yellow
            python -m pip install "Pillow" "pynput" -ErrorAction Stop
        }
        Pop-Location
        Log-Message "Python-Abhängigkeiten erfolgreich installiert."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Installieren von Python-Abhängigkeiten: $_" -Color Red
        return $false
    }
}

function Download-AndExtractClient {
    param([string]$ZipUrl, [string]$DestinationDir, [string]$RelativePathInZip, [string]$TargetFileName)
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
            Log-Message "FEHLER: Client-Ordner '$SourceClientFolder' NICHT im extrahierten ZIP gefunden. Überprüfen Sie \$GitHubClientRelativePathInZip!" -Color Red
            return $false
        }
        if (Test-Path $DestinationDir) { Remove-Item $DestinationDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $DestinationDir | Out-Null
        Log-Message "Kopiere Client-Dateien von '$SourceClientFolder' nach '$DestinationDir'..."
        Copy-Item -Path (Join-Path $SourceClientFolder "*") -Destination $DestinationDir -Recurse -Force
        Log-Message "Client-Dateien erfolgreich nach '$DestinationDir' kopiert."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Herunterladen oder Entpacken des Clients von GitHub: $_" -Color Red
        return $false
    } finally {
        if (Test-Path $TempZipPath) { Remove-Item $TempZipPath -ErrorAction SilentlyContinue }
        if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Setup-ClientAutoStart {
    Log-Message "Richte automatischen Start des Clients ein..."
    $taskAction = "python.exe ""$ClientScriptPath"""
    
    try {
        # Löscht die Aufgabe, falls sie schon existiert
        Log-Message "Lösche bestehende geplante Aufgabe '$SchedulerTaskName', falls vorhanden."
        schtasks /delete /tn "$SchedulerTaskName" /f | Out-Null
        
        # Erstellt die neue geplante Aufgabe mit schtasks
        Log-Message "Erstelle neue geplante Aufgabe mit schtasks.exe..."
        $schtasksCmd = "schtasks /create /tn ""$SchedulerTaskName"" /tr ""$taskAction"" /sc onstart /ru SYSTEM /f"
        $result = Invoke-Expression $schtasksCmd
        Log-Message "Geplante Aufgabe '$SchedulerTaskName' erfolgreich erstellt."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Erstellen der geplanten Aufgabe mit schtasks: $_" -Color Red
        return $false
    }
}

# --- Haupt-Logik des Skripts ---
Log-Message "------------------------------------------------------------------------------------------------------------------"
Log-Message "STARTE VM CLIENT INSTALLATIONSSKRIPT"
Log-Message "------------------------------------------------------------------------------------------------------------------"

try {
    if (-not (Download-AndExtractClient -ZipUrl $GitHubRepoZipUrl -DestinationDir $ClientAppDir -RelativePathInZip $GitHubClientRelativePathInZip -TargetFileName $ClientScriptName)) {
        throw "FATALER FEHLER: Konnte Client-Dateien von GitHub nicht herunterladen oder entpacken."
    }
    if (-not (Test-PythonInstallation)) {
        Log-Message "Python nicht gefunden oder falsche Version. Versuche Installation..."
        if (-not (Install-Python)) {
            throw "FATALER FEHLER: Konnte Python nicht installieren. Bitte prüfen Sie Ihre Internetverbindung und Berechtigungen."
        }
    }
    if (-not (Install-PythonDependencies)) {
        throw "FATALER FEHLER: Konnte Python-Abhängigkeiten nicht installieren. Bitte prüfen Sie die Log-Ausgabe."
    }
    if (-not (Setup-ClientAutoStart)) {
        throw "FATALER FEHLER: Fehler beim Einrichten des automatischen Starts."
    }

    Log-Message "------------------------------------------------------------------------------------------------------------------"
    Log-Message "INSTALLATION ABGESCHLOSSEN!" -Color Green
    Log-Message "Der VM Client sollte beim nächsten Neustart der VM automatisch starten."
    Log-Message "Sie können den Client manuell starten, indem Sie 'python $ClientScriptPath' in einer PowerShell ausführen."
    Log-Message "------------------------------------------------------------------------------------------------------------------"

} catch {
    Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Red
    Log-Message "FEHLER WÄHREND DER INSTALLATION!" -Color Red
    Log-Message "Fehlermeldung: $($_.Exception.Message)" -Color Red
    Log-Message "Bitte überprüfen Sie die oben stehenden Meldungen für weitere Details zum Problem." -Color Red
    Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Red
    $scriptError = $true
}

Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Yellow
Log-Message "WICHTIGER HINWEIS:" -Color Yellow
Log-Message "1. Stellen Sie sicher, dass 'server_app.py' auf dem Haupt-PC läuft." -Color Yellow
Log-Message "2. Stellen Sie sicher, dass Ihr DynDNS-Client (DUC) auf dem Haupt-PC läuft." -Color Yellow
Log-Message "3. Stellen Sie sicher, dass die Port-Weiterleitung im Router zum Haupt-PC korrekt ist." -Color Yellow
Log-Message "4. Stellen Sie sicher, dass Ihre Windows-Firewall auf dem Haupt-PC den Port 62345 (TCP eingehend) zulässt." -Color Yellow
Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Yellow

if ($scriptError) {
    exit 1
} else {
    exit 0
}
