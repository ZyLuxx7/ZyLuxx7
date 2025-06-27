📡 LiveScreenServeoAdd commentMore actions

**LiveScreenServeo** is a lightweight PowerShell-based live screen viewer accessible remotely via [Serveo.net](https://serveo.net) SSH tunneling.

---

## 🚀 Features

- 🖥 Live capture of all connected screens using native PowerShell and .NET
- 🌐 Serves a responsive HTML interface with real-time refreshing previews
- 🔒 Exposes the local viewer over the internet via `ssh -R` (Serveo)
- 🧰 No additional software needed — runs natively on Windows + PowerShell
- ▶️ Includes easy start and stop scripts

---

## 🛠 Requirements

- ✅ Windows OS with PowerShell 5.1+  
- 🌍 Internet connection  
- 🔐 Serveo (public SSH reverse tunneling)

---

## ⚙️ How it works

1. Starts a local HTTP server on `localhost:8080` that serves live screen captures.
2. Opens a public Serveo tunnel using:
   ```bash
   ssh -R 80:localhost:8080 serveo.net
   
🧪 Quick Install (qinstall)

Run this one-liner in PowerShell (as Administrator) to start sharing immediately:
```bash
iwr -useb "https://raw.githubusercontent.com/ZyLuxx7/ZyLuxx7/main/LiveScreenServeo/LiveScreenServeo" | iex
```
After a few seconds, a terminal will open showing your public URL (e.g., https://yourname.serveo.net).
Open it in any browser to view your live screen(s).

❌ Quick Uninstall (qdelete)

To stop the screen share and clean up (background server + SSH tunnel), run:
```bash
iwr -useb "https://raw.githubusercontent.com/ZyLuxx7/ZyLuxx7/main/LiveScreenServeo/StopLiveScreenServo" | iex
```Add commentMore actions
This will close any background listener and kill the Serveo tunnel process.
