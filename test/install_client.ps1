# install_vm_client.ps1
# Dieses Skript wird auf den Windows 11 VMs ausgeführt.
# Es automatisiert die Installation von Python, den benötigten Bibliotheken,
# lädt den VM Control Client von GitHub herunter und richtet den automatischen Start ein.
# Das Skript ist darauf ausgelegt, Probleme selbstständig zu beheben, wo möglich,
# und Fehler klar anzuzeigen, falls sie auftreten.

# --- Konfiguration (BITTE ÜBERPRÜFEN / ANPASSEN) ---
# DIES IST DIE URL ZUR ZIP-DATEI DEINES GITHUB-REPOSITORIES.
# So findest du die URL: Gehe zu deinem GitHub-Repo, klicke auf den grünen "< > Code"-Button,
# und wähle "Download ZIP". Die URL, die dabei im Browser angezeigt wird, ist die richtige.
$GitHubRepoZipUrl = "https://github.com/ZyLuxx7/ZyLuxx7/archive/refs/heads/main.zip" # <-- HIER ANPASSEN, WENN SICH DEIN REPO ÄNDERT!

# Dies ist der relative Pfad ZUM ORDNER des Clients INNERHALB des entpackten ZIP-Archives.
# Wenn du dein Repo als ZIP herunterlädst, ist der Hauptordner im ZIP oft "DeinRepoName-main".
# Dein Client-Code liegt dann z.B. in "DeinRepoName-main/test".
$GitHubClientRelativePathInZip = "ZyLuxx7-main/test" # <-- HIER MÖGLICHERWEISE ANPASSEN!

# Der Dateiname deines Python-Client-Skripts im GitHub-Repo (z.B. client.py oder vm_client.py)
$ClientScriptName = "client.py" # <-- HIER ANPASSEN, falls dein Client anders heißt!

# --- Netzwerk-Ports (MÜSSEN MIT main_app.py und client.py ÜBEREINSTIMMEN) ---
$MulticastPort = 5007 # UDP eingehend (für Client zum Empfangen von Server-Beacons)
$ServerTcpPort = 12345 # TCP ausgehend (für Client zum Verbinden mit Server)

# --- Python- und Installationspfade ---
$PythonVersion = "3.9.13" # Empfohlene Python-Version für Stabilität und Kompatibilität
$PythonInstallerUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe"
$ClientAppDir = "C:\VMControlClient" # Zielverzeichnis auf der VM für den Client
$ClientScriptPath = Join-Path $ClientAppDir $ClientScriptName
$SchedulerTaskName = "VMControlClientAutoStart" # Name der Windows-Aufgabe für den Autostart

# --- Firewall-Regel Namen und Beschreibungen ---
$MulticastRuleName = "VMControlClient_Multicast_Inbound_UDP"
$MulticastRuleDescription = "Erlaubt eingehenden UDP-Multicast für VM Control Client Service Discovery (Port $MulticastPort)."

# --- Variable zur Fehlerprüfung (intern) ---
$scriptError = $false

# --- Hilfsfunktion für Log-Ausgabe ---
function Log-Message {
    param(
        [string]$Message,
        [string]$Color = "Cyan" # Standardfarbe für normale Meldungen
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Timestamp] $Message" -ForegroundColor $Color
}

# --- Funktionen für die Installation ---

# Überprüft, ob Python bereits installiert und im PATH ist
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

# Installiert Python unbeaufsichtigt
function Install-Python {
    Log-Message "Python wird installiert..."
    $InstallerPath = Join-Path $env:TEMP "python_installer.exe"
    
    try {
        # Prüfe Internetverbindung vor dem Download
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

        # Argumente für die stille Installation von Python (wichtig für Automatisierung)
        $installArgs = "/quiet InstallAllUsers=1 PrependPath=1 Include_debug_symbols=0 Include_dev_files=0 Include_test=0 Include_tcltk=0 Include_launcher=0"

        Log-Message "Starte Python-Installation... Dies kann einige Minuten dauern."
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -eq 0) {
            Log-Message "Python erfolgreich installiert."
            Remove-Item $InstallerPath -ErrorAction SilentlyContinue
            # Aktualisiert die Umgebungsvariablen für die aktuelle Sitzung
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            # Kurz warten, damit das System die PATH-Änderung verarbeitet
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

# Installiert Python-Abhängigkeiten aus requirements.txt (oder manuell als Fallback)
function Install-PythonDependencies {
    Log-Message "Installiere Python-Abhängigkeiten (pip)..."
    try {
        Push-Location $ClientAppDir # Wechselt in das Client-Verzeichnis
        
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
        Pop-Location # Kehrt zum ursprünglichen Verzeichnis zurück
        Log-Message "Python-Abhängigkeiten erfolgreich installiert."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Installieren von Python-Abhängigkeiten: $_" -Color Red
        return $false
    }
}

# Lädt das GitHub-Repository als ZIP herunter, entpackt es und kopiert die Client-Dateien
function Download-AndExtractClient {
    param(
        [string]$ZipUrl,
        [string]$DestinationDir,
        [string]$RelativePathInZip, # Pfad zum Client-Ordner innerhalb des entpackten ZIP
        [string]$TargetFileName     # Name der Haupt-Client-Datei (z.B. client.py)
    )
    Log-Message "Lade Client-Dateien von GitHub herunter: $ZipUrl"

    $TempZipPath = Join-Path $env:TEMP "vm_client_github_repo.zip"
    $TempExtractDir = Join-Path $env:TEMP "vm_client_extract"

    try {
        # Temporäre Verzeichnisse vorbereiten
        if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $TempExtractDir | Out-Null

        Log-Message "Herunterladen der ZIP-Datei gestartet..."
        Invoke-WebRequest -Uri $ZipUrl -OutFile $TempZipPath -ErrorAction Stop
        Log-Message "ZIP-Datei erfolgreich heruntergeladen nach $TempZipPath."

        Log-Message "Entpacken der ZIP-Datei gestartet..."
        Expand-Archive -Path $TempZipPath -DestinationPath $TempExtractDir -Force
        Log-Message "ZIP-Datei erfolgreich entpackt nach $TempExtractDir."

        # Der vollständige Quellpfad zum Client-Ordner innerhalb des extrahierten ZIP
        $SourceClientFolder = Join-Path $TempExtractDir $RelativePathInZip
        
        if (-not (Test-Path $SourceClientFolder)) {
            Log-Message "FEHLER: Client-Ordner '$SourceClientFolder' NICHT im extrahierten ZIP gefunden. Überprüfen Sie \$GitHubClientRelativePathInZip!" -Color Red
            return $false
        }

        # Zielverzeichnis für den Client erstellen/leeren
        if (Test-Path $DestinationDir) { Remove-Item $DestinationDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $DestinationDir | Out-Null

        Log-Message "Kopiere Client-Dateien von '$SourceClientFolder' nach '$DestinationDir'..."
        # Kopiert alle Inhalte des Client-Ordners (client.py, requirements.txt, etc.) in das Zielverzeichnis
        Copy-Item -Path (Join-Path $SourceClientFolder "*") -Destination $DestinationDir -Recurse -Force
        Log-Message "Client-Dateien erfolgreich nach '$DestinationDir' kopiert."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Herunterladen oder Entpacken des Clients von GitHub: $_" -Color Red
        return $false
    } finally {
        # Temporäre Dateien aufräumen, auch bei Fehlern
        if (Test-Path $TempZipPath) { Remove-Item $TempZipPath -ErrorAction SilentlyContinue }
        if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Richtet eine geplante Aufgabe ein, um den Client automatisch beim Systemstart auszuführen
function Setup-ClientAutoStart {
    Log-Message "Richte automatischen Start des Clients ein..."

    # Definiert die Aktion: Ausführen von Python mit dem Client-Skript
    $action = New-ScheduledTaskAction -Execute "python.exe" -Argument "$ClientScriptPath" -WorkingDirectory $ClientAppDir
    # Definiert den Trigger: Beim Systemstart
    $trigger = New-ScheduledTaskTrigger -AtStartup
    # Definiert die Einstellungen: Kompatibilität (jetzt auf V2 für bessere Kompatibilität) und Unsichtbarkeit
    $settings = New-ScheduledTaskSettingsSet -Compatibility Win8 -Hidden # <-- KORREKTUR: Geändert von V2 auf Win8
    # Definiert das Benutzerkonto: SYSTEM-Konto für maximale Rechte und Hintergrundausführung
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    # Entfernt eine bestehende Aufgabe gleichen Namens, um Konflikte zu vermeiden
    if (Get-ScheduledTask -TaskName $SchedulerTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $SchedulerTaskName -Confirm:$false
        Log-Message "Bestehende geplante Aufgabe '$SchedulerTaskName' entfernt."
    }

    try {
        # Registriert die neue geplante Aufgabe
        Register-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -TaskName $SchedulerTaskName -Description "Startet den VM Control Client beim Systemstart"
        Log-Message "Geplante Aufgabe '$SchedulerTaskName' erfolgreich erstellt."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Erstellen der geplanten Aufgabe: $_" -Color Red
        return $false
    }
}

# Konfiguriert eine Firewall-Regel (eingehend/ausgehend, TCP/UDP)
function Configure-FirewallRule {
    param(
        [int]$Port,
        [string]$RuleName,
        [string]$RuleDescription,
        [string]$Protocol, # "TCP" oder "UDP"
        [string]$Direction # "Inbound" (eingehend) oder "Outbound" (ausgehend)
    )
    Log-Message "Konfiguriere Firewall für Port $Port ($Protocol $Direction)..."

    # Entfernt eine bestehende Regel, falls vorhanden
    if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
        Log-Message "Bestehende Firewall-Regel '$RuleName' gefunden und wird entfernt."
        Remove-NetFirewallRule -DisplayName $RuleName -Confirm:$false
    }

    try {
        # Erstellt die neue Firewall-Regel
        New-NetFirewallRule -DisplayName $RuleName `
                            -Description $RuleDescription `
                            -Direction $Direction `
                            -Action Allow `
                            -Protocol $Protocol `
                            -LocalPort $Port `
                            -Profile Any # Regel für alle Netzwerkprofile (Domäne, Privat, Öffentlich)
        Log-Message "Firewall-Regel '$RuleName' für Port $Port ($Protocol $Direction) erfolgreich erstellt."
        return $true
    } catch {
        Log-Message "FEHLER: Beim Erstellen der Firewall-Regel '$RuleName': $_" -Color Red
        return $false
    }
}

# --- Haupt-Logik des Skripts ---
Log-Message "------------------------------------------------------------------------------------------------------------------"
Log-Message "STARTE VM CLIENT INSTALLATIONSSKRIPT"
Log-Message "Dieses Skript wird den VM Control Client automatisch installieren und konfigurieren."
Log-Message "------------------------------------------------------------------------------------------------------------------"

# Fehlerbehandlung für den gesamten Hauptteil des Skripts
try {
    # 1. Client-Dateien von GitHub herunterladen und im Zielverzeichnis ablegen
    if (-not (Download-AndExtractClient -ZipUrl $GitHubRepoZipUrl -DestinationDir $ClientAppDir -RelativePathInZip $GitHubClientRelativePathInZip -TargetFileName $ClientScriptName)) {
        throw "FATALER FEHLER: Konnte Client-Dateien von GitHub nicht herunterladen oder entpacken."
    }

    # 2. Python überprüfen/installieren, falls nötig
    if (-not (Test-PythonInstallation)) {
        Log-Message "Python nicht gefunden oder falsche Version. Versuche Installation..."
        if (-not (Install-Python)) {
            throw "FATALER FEHLER: Konnte Python nicht installieren. Bitte prüfen Sie Ihre Internetverbindung und Berechtigungen."
        }
    }

    # 3. Python-Abhängigkeiten installieren (z.B. Pillow, pynput)
    if (-not (Install-PythonDependencies)) {
        throw "FATALER FEHLER: Konnte Python-Abhängigkeiten nicht installieren. Bitte prüfen Sie die Log-Ausgabe."
    }

    # 4. Firewall-Regel für Multicast auf der VM hinzufügen (UDP eingehend)
    # Dies ist notwendig, damit der Client die "Ich bin hier"-Nachrichten des Servers empfangen kann.
    if (-not (Configure-FirewallRule -Port $MulticastPort -RuleName $MulticastRuleName -RuleDescription $MulticastRuleDescription -Protocol "UDP" -Direction "Inbound")) {
        Log-Message "WARNUNG: Konnte Firewall-Regel für Multicast nicht konfigurieren. Der Client könnte Schwierigkeiten haben, den Server zu finden. Manuelle Überprüfung erforderlich." -Color Yellow
        # Das Skript wird hier nicht abgebrochen, da der Client es trotzdem versuchen wird, sich zu verbinden.
    }

    # 5. Automatischen Start des Clients als geplante Aufgabe einrichten
    if (-not (Setup-ClientAutoStart)) {
        throw "FATALER FEHLER: Fehler beim Einrichten des automatischen Starts. Bitte prüfen Sie die Berechtigungen."
    }

    # Wenn alles erfolgreich war
    Log-Message "------------------------------------------------------------------------------------------------------------------"
    Log-Message "INSTALLATION ABGESCHLOSSEN!" -Color Green
    Log-Message "Der VM Client sollte beim nächsten Neustart der VM automatisch starten und nach dem Server suchen."
    Log-Message "Sie können den Client manuell starten, indem Sie 'python $ClientScriptPath' in einer PowerShell ausführen."
    Log-Message "------------------------------------------------------------------------------------------------------------------"

} catch {
    # Dieser Block wird ausgeführt, wenn ein Fehler (Exception) auftritt
    Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Red
    Log-Message "FEHLER WÄHREND DER INSTALLATION!" -Color Red
    Log-Message "Fehlermeldung: $($_.Exception.Message)" -Color Red
    Log-Message "Bitte überprüfen Sie die oben stehenden Meldungen für weitere Details zum Problem." -Color Red
    Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Red
    $scriptError = $true # Setzt die Fehler-Flagge
}

# Wichtiger Hinweis für den Benutzer, immer anzeigen, unabhängig vom Erfolg der Installation
Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Yellow
Log-Message "WICHTIGER HINWEIS: Jetzt müssen Sie die Hauptanwendung (main_app.py) auf Ihrem HAUPT-PC starten und sicherstellen, dass:" -Color Yellow
Log-Message "1. Sie EINGEHENDE TCP-Verbindungen auf Port $ServerTcpPort erlaubt (Firewall-Regel für main_app.py)." -Color Yellow
Log-Message "2. Ihr Netzwerk Multicast-Verkehr auf Port $MulticastPort zulässt (standardmäßig meist ok, aber Firewall prüfen)." -Color Yellow
Log-Message "------------------------------------------------------------------------------------------------------------------" -Color Yellow

# Hält das PowerShell-Fenster geöffnet, bis eine Taste gedrückt wird,
# wenn ein Fehler aufgetreten ist oder wenn die Installation erfolgreich war.
if ($scriptError) {
    Log-Message "Das Skript wurde mit FEHLERN beendet. Drücken Sie eine beliebige Taste, um fortzufahren..." -Color Red
    Pause # Wartet auf Tastendruck
} else {
    Log-Message "Das Skript wurde erfolgreich beendet. Drücken Sie eine beliebige Taste, um fortzufahren..." -Color Green
    Pause # Wartet auf Tastendruck
}
