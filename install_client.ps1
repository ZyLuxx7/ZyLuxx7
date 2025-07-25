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
    param(
        [string]$Message,
        [string]$Color = "Cyan"
    )
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
        Log-Message "Prüfe Internetverbindung zum Herunterladen des Python-Installers..."
        try {
            $webRequest = Invoke-WebRequest -Uri "http://www.google.com" -UseBasicParsing -ErrorAction SilentlyContinue -TimeoutSec 10
            if ($webRequest.StatusCode -ne 200) {
                Log-Message "WARNUNG: Keine aktive Internetverbindung oder Zugriff auf Google.com. Python-Download könnte fehlschlagen." -Color Yellow
            } else {
                Log-Message "Internetverbindung scheint aktiv."
            }
        } catch {
            Log-Message "FEHLER: Internetverbindungstest fehlgeschlagen: $_. Python-Download könnte fehlschlagen." -Color Red
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
            Start-Sleep -Seconds 2
            return $true
        } else {
            Log-Message "FEHLER: Python-Installation fehlgeschlagen. Exit Code: $($process.ExitCode). Prüfen Sie das Installationslog, falls verfügbar." -Color Red
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
        Log-Message "Lösche bestehende geplante Aufgabe '$SchedulerTaskName', falls vorhanden."
        schtasks /delete /tn "$SchedulerTaskName" /f | Out-Null
        $schtasksCmd = "schtasks /create /tn ""$SchedulerTaskName"" /tr ""$taskAction"" /sc onstart /ru SYSTEM /f"
        $result = Invoke-Expression $schtasksCmd
        Log-Message "Geplante Aufgabe '$SchedulerTaskName' erfolgreich erstellt."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Erstellen der geplanten Aufgabe mit schtasks: $_" -Color Red
        return $false
    }
}

# --- NEUE FUNKTION: Führt die finalen Checks durch ---
function Run-FinalChecks {
    Log-Message "------------------------------------------------------------------------------------------------------------------"
    Log-Message "DURCHFÜHRUNG DER FINALEN PRÜFUNG..." -Color Yellow
    $success = $true

    # 1. Prüfe, ob Python im PATH ist
    if (Get-Command python.exe -ErrorAction SilentlyContinue) {
        Log-Message "✅ Python im System-PATH gefunden." -Color Green
    } else {
        Log-Message "❌ Python nicht im System-PATH gefunden." -Color Red; $success = $false
    }

    # 2. Prüfe, ob die Client-Datei existiert
    if (Test-Path $ClientScriptPath) {
        Log-Message "✅ Client-Skript '$ClientScriptName' am korrekten Ort gefunden." -Color Green
    } else {
        Log-Message "❌ Client-Skript '$ClientScriptName' nicht gefunden." -Color Red; $success = $false
    }

    # 3. Prüfe, ob die geplante Aufgabe existiert
    if (schtasks /query /tn "$SchedulerTaskName" | Select-String "SUCCESS") {
        Log-Message "✅ Geplante Aufgabe '$SchedulerTaskName' erfolgreich erstellt." -Color Green
    } else {
        Log-Message "❌ Geplante Aufgabe '$SchedulerTaskName' nicht gefunden." -Color Red; $success = $false
    }
    
    # 4. Prüfe, ob die Abhängigkeiten installiert sind (einfache Prüfung)
    try {
        python -c "import pynput, PIL" -ErrorAction Stop
        Log-Message "✅ Python-Abhängigkeiten (pynput, Pillow) installiert." -Color Green
    } catch {
        Log-Message "❌ Python-Abhängigkeiten nicht installiert oder Fehler." -Color Red; $success = $false
    }

    Log-Message "------------------------------------------------------------------------------------------------------------------"
    if ($success) {
        Log-Message "ALLE PRÜFUNGEN ERFOLGREICH BESTANDEN!" -Color Green
    } else {
        Log-Message "WARNUNG: EINIGE PRÜFUNGEN SIND FEHLGESCHLAGEN. ÜBERPRÜFEN SIE DIE OBEREN MELDUNGEN." -Color Red
    }
    Log-Message "------------------------------------------------------------------------------------------------------------------"

    return $success
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
    Log-Message "INSTALLATIONSPROZESS ABGESCHLOSSEN." -Color Green
    Log-Message "Führe finale Prüfung durch..."
    $checkResult = Run-FinalChecks

} catch {
    Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Red
    Log-Message "FEHLER WÄHREND DER INSTALLATION!" -Color Red
    Log-Message "Fehlermeldung: $($_.Exception.Message)" -Color Red
    Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Red
    $scriptError = $true
}

Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Yellow
Log-Message "WICHTIGER HINWEIS FÜR HAUPT-PC (SERVER):" -Color Yellow
Log-Message "1. Stelle sicher, dass 'server_app.py' läuft." -Color Yellow
Log-Message "2. Stelle sicher, dass dein DynDNS-Client (DUC) auf dem Haupt-PC läuft." -Color Yellow
Log-Message "3. Stelle sicher, dass die Port-Weiterleitung im Router zum Haupt-PC korrekt ist." -Color Yellow
Log-Message "4. Stelle sicher, dass deine Windows-Firewall den Port 62345 (TCP eingehend) zulässt." -Color Yellow
Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Yellow

if ($scriptError) {
    Log-Message "Das Skript ist mit FEHLERN beendet worden. Es wird in 5 Sekunden geschlossen." -Color Red
    Start-Sleep -Seconds 5
    exit 1
} else {
    Log-Message "Das Skript wurde erfolgreich beendet. Es wird in 1 Sekunde geschlossen." -Color Green
    Start-Sleep -Seconds 15
    exit 0
}
