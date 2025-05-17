# LiveScreenServeo

📡 A lightweight PowerShell-based live screen viewer accessible remotely via Serveo SSH tunneling.

## 🚀 Features

- Live capture of all connected screens using PowerShell and .NET
- Serves an HTML interface with real-time refreshing previews
- Exposes the local viewer over the internet via `ssh -R` (Serveo)
- Requires no extra software — native Windows + PowerShell
- Start and Stop scripts included

## 🛠 Requirements

- Windows OS with PowerShell
- Internet connection
- Serveo (SSH tunneling service)

## 🧩 How it works

1. Starts a local HTTP server (`localhost:8080`) to serve live screen images.
2. Opens a public tunnel via Serveo:  
   `ssh -R 80:localhost:8080 serveo.net`
3. Displays all screens in a responsive HTML dashboard.

## 📂 Usage

### 🟢 Start

Run the main script as administrator:

```powershell
.\start-liveshare.ps1
