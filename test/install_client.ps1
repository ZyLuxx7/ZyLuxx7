# install_vm_client.ps1
# Dieses Skript wird auf den Windows 11 VMs ausgeführt.
# Es automatisiert die Installation von Python, den benötigten Bibliotheken,
# lädt den VM Control Client von GitHub herunter und richtet den automatischen Start ein.

# --- Konfiguration (BITTE ANPASSEN) ---
# DIES IST DIE KORREKTE URL FÜR DEIN REPO-ZIP.
$GitHubRepoZipUrl = "https://github.com/ZyLuxx7/ZyLuxx7/archive/refs/heads/main.zip"

# Dies ist der Name des Ordners IM ENTPACKTEN ZIP, in dem sich client.py und requirements.txt befinden.
# Wenn du dein Repo als ZIP herunterlädst, ist der Hauptordner im ZIP "ZyLuxx7-main".
# Dein Client-Code liegt dann in "ZyLuxx7-main/test".
$GitHubClientRelativePathInZip = "ZyLuxx7-main/test" # <-- HIER WICHTIG ANPASSEN!

# Der Name der Client-Datei in deinem Repository (client.py)
$ClientScriptName = "client.py"

# --- Ports für die Kommunikation (müssen mit dem Python-Client und Server übereinstimmen) ---
# Multicast-Port für die automatische Server-Erkennung (UDP eingehend auf der VM)
$MulticastPort = 5007

# TCP-Port für die eigentliche Steuerungsverbindung (ausgehend von der VM zum Server)
$ServerTcpPort = 12345

# --- Installationspfade und Namen ---
$PythonVersion = "3.9.13" # Empfohlene Python-Version für Stabilität
$PythonInstallerUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe"
$ClientAppDir = "C:\VMControlClient" # Zielverzeichnis für den Client auf der VM
$ClientScriptPath = Join-Path $ClientAppDir $ClientScriptName
$SchedulerTaskName = "VMControlClientAutoStart" # Name der geplanten Aufgabe für den Autostart

# --- Firewall-Regel Namen und Beschreibungen ---
$MulticastRuleName = "VMControlClient_Multicast_Inbound_UDP"
$MulticastRuleDescription = "Erlaubt eingehenden UDP-Multicast für VM Control Client Service Discovery (Port $MulticastPort)."

# --- Hilfsfunktion für Logging ---
function Log-Message {
    param(
        [string]$Message
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Timestamp] $Message"
}

# --- Funktionen für die Installation ---

# Überprüft, ob Python bereits installiert ist
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

# Installiert Python unbeaufsichtigt
function Install-Python {
    Log-Message "Python wird installiert..."
    $InstallerPath = Join-Path $env:TEMP "python_installer.exe"
    
    try {
        Invoke-WebRequest -Uri $PythonInstallerUrl -OutFile $InstallerPath -ErrorAction Stop
        Log-Message "Python-Installer heruntergeladen."

        $installArgs = "/quiet InstallAllUsers=1 PrependPath=1 Include_debug_symbols=0 Include_dev_files=0 Include_test=0 Include_tcltk=0 Include_launcher=0"

        $process = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -eq 0) {
            Log-Message "Python erfolgreich installiert."
            Remove-Item $InstallerPath -ErrorAction SilentlyContinue
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            return $true
        } else {
            Log-Message "Fehler bei der Python-Installation. Exit Code: $($process.ExitCode)"
            return $false
        }
    } catch {
        Log-Message "Fehler beim Herunterladen oder Ausführen des Python-Installers: $_"
        return $false
    }
}

# Installiert Python-Abhängigkeiten aus requirements.txt (oder manuell als Fallback)
function Install-PythonDependencies {
    Log-Message "Installiere Python-Abhängigkeiten (pip)..."
    try {
        Push-Location $ClientAppDir
        
        python -m pip install --upgrade pip -ErrorAction Stop
        Log-Message "pip auf neueste Version aktualisiert."

        if (Test-Path (Join-Path $ClientAppDir "requirements.txt")) {
            Log-Message "requirements.txt gefunden. Installiere Abhängigkeiten daraus."
            python -m pip install -r requirements.txt -ErrorAction Stop
        } else {
            Log-Message "requirements.txt nicht gefunden. Installiere Standard-Abhängigkeiten (Pillow, pynput)..."
            python -m pip install "Pillow" "pynput" -ErrorAction Stop
        }
        Pop-Location
        Log-Message "Python-Abhängigkeiten erfolgreich installiert."
        return $true
    } catch {
        Log-Message "Fehler beim Installieren von Python-Abhängigkeiten: $_"
        return $false
    }
}

# Lädt das GitHub-Repository als ZIP herunter, entpackt es und kopiert die Client-Dateien
function Download-AndExtractClient {
    param(
        [string]$ZipUrl,
        [string]$DestinationDir,
        [string]$RelativePathInZip, # Der Pfad zum Client-Ordner innerhalb des entpackten ZIP
        [string]$TargetFileName     # Der Name der Client-Datei (z.B. client.py)
    )
    Log-Message "Lade Client-Dateien von GitHub herunter: $ZipUrl"

    $TempZipPath = Join-Path $env:TEMP "vm_client_github_repo.zip"
    $TempExtractDir = Join-Path $env:TEMP "vm_client_extract"

    try {
        if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $TempExtractDir | Out-Null

        Invoke-WebRequest -Uri $ZipUrl -OutFile $TempZipPath -ErrorAction Stop
        Log-Message "ZIP-Datei erfolgreich heruntergeladen nach $TempZipPath."

        Expand-Archive -Path $TempZipPath -DestinationPath $TempExtractDir -Force
        Log-Message "ZIP-Datei erfolgreich entpackt nach $TempExtractDir."

        # Der vollständige Quellpfad zum Client-Ordner innerhalb des extrahierten ZIP
        $SourceClientFolder = Join-Path $TempExtractDir $RelativePathInZip
        
        if (-not (Test-Path $SourceClientFolder)) {
            Log-Message "Fehler: Client-Ordner '$SourceClientFolder' nicht im extrahierten ZIP gefunden."
            return $false
        }

        if (Test-Path $DestinationDir) { Remove-Item $DestinationDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $DestinationDir | Out-Null

        # Kopiert alle Inhalte des Client-Ordners (client.py, requirements.txt, etc.) in das Zielverzeichnis
        Copy-Item -Path (Join-Path $SourceClientFolder "*") -Destination $DestinationDir -Recurse -Force
        Log-Message "Client-Dateien von '$SourceClientFolder' erfolgreich nach '$DestinationDir' kopiert."
        return $true
    } catch {
        Log-Message "Fehler beim Herunterladen oder Entpacken des Clients von GitHub: $_"
        return $false
    } finally {
        if (Test-Path $TempZipPath) { Remove-Item $TempZipPath -ErrorAction SilentlyContinue }
        if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Richtet eine geplante Aufgabe ein, um den Client automatisch beim Systemstart auszuführen
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
        Log-Message "Fehler beim Erstellen der geplanten Aufgabe: $_"
        return $false
    }
}

# Konfiguriert eine Firewall-Regel (eingehend/ausgehend, TCP/UDP)
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
        Log-Message "Fehler beim Erstellen der Firewall-Regel '$RuleName': $_"
        return $false
    }
}

# --- Haupt-Logik des Skripts ---
Log-Message "Starte VM Client Installationsskript (Herunterladen von GitHub und selbstregelnd)."

# 1. Client-Dateien von GitHub herunterladen und im Zielverzeichnis ablegen
# Nun mit dem korrekten relativen Pfad innerhalb des ZIP-Archivs
if (-not (Download-AndExtractClient -ZipUrl $GitHubRepoZipUrl -DestinationDir $ClientAppDir -RelativePathInZip $GitHubClientRelativePathInZip -TargetFileName $ClientScriptName)) {
    Log-Message "Konnte Client-Dateien von GitHub nicht herunterladen oder entpacken. Skript wird beendet."
    Exit 1
}

# 2. Python überprüfen/installieren, falls nötig
if (-not (Test-PythonInstallation)) {
    Log-Message "Python nicht gefunden oder falsche Version. Versuche Installation..."
    if (-not (Install-Python)) {
        Log-Message "Konnte Python nicht installieren. Skript wird beendet."
        Exit 1
    }
}

# 3. Python-Abhängigkeiten installieren (z.B. Pillow, pynput)
if (-not (Install-PythonDependencies)) {
    Log-Message "Konnte Python-Abhängigkeiten nicht installieren. Skript wird beendet."
    Exit 1
}

# 4. Firewall-Regel für Multicast auf der VM hinzufügen (UDP eingehend)
if (-not (Configure-FirewallRule -Port $MulticastPort -RuleName $MulticastRuleName -RuleDescription $MulticastRuleDescription -Protocol "UDP" -Direction "Inbound")) {
    Log-Message "Konnte Firewall-Regel für Multicast nicht konfigurieren. Der Client könnte Schwierigkeiten haben, den Server zu finden."
}

# 5. Automatischen Start des Clients als geplante Aufgabe einrichten
if (-not (Setup-ClientAutoStart)) {
    Log-Message "Fehler beim Einrichten des automatischen Starts. Skript wird beendet."
    Exit 1
}

Log-Message "Installation abgeschlossen. Der VM Client sollte beim nächsten Neustart der VM automatisch starten und nach dem Server suchen."
Log-Message "Sie können den Client manuell starten, indem Sie 'python $ClientScriptPath' in einer PowerShell ausführen."

Log-Message "------------------------------------------------------------------------------------------------------------------"
Log-Message "WICHTIGER HINWEIS: Jetzt müssen Sie den SERVER auf Ihrem HAUPT-PC starten und sicherstellen, dass:"
Log-Message "1. Er EINGEHENDE TCP-Verbindungen auf Port $ServerTcpPort erlaubt (Firewall-Regel)."
Log-Message "2. Er AUSGEHENDE UDP-Multicast-Beacons auf Port $MulticastPort sendet (Firewall-Regel für ausgehende UDP-Pakete kann nötig sein)."
Log-Message "------------------------------------------------------------------------------------------------------------------"
