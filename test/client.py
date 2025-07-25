# client.py (Der VM-Client, der auf den VMs läuft)

import socket
import time
import os
import json
import subprocess
# Importe für Screenshot und Eingabe-Injektion kommen hier später hinzu

# --- Globale Netzwerk-Konfiguration für den Client ---
# WICHTIG: Ersetze dies durch den Hostnamen deines DynDNS-Dienstes (z.B. 'mein-steuer-server.ddns.net')
SERVER_HOST = 'DEIN_DYNDNS_HOSTNAME' # <-- HIER ANPASSEN!
SERVER_PORT = 62345 # Muss mit dem SERVER_PORT in server_app.py übereinstimmen

# --- SICHERHEITS-KONFIGURATION ---
# MUSS EXAKT MIT DEM SECRET KEY AUF DEM SERVER ÜBEREINSTIMMEN
SHARED_SECRET_KEY = "sYc3aQ!t9LzX@p0Kj8UvB#n7M5r*W2e1Y" # <-- HIER ANPASSEN!

CLIENT_NAME = os.environ.get('COMPUTERNAME', 'UnknownVM')

def get_local_ip():
    """Versucht, die lokale IP-Adresse der VM zu ermitteln."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('10.255.255.255', 1))
        IP = s.getsockname()[0]
    except Exception:
        IP = '127.0.0.1'
    finally:
        s.close()
    return IP

def connect_to_server(server_host, server_port):
    """Versucht, sich mit dem Server über den DynDNS-Hostnamen zu verbinden und sich zu authentifizieren."""
    client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        print(f"[{CLIENT_NAME}] Versuche Verbindung zu {server_host}:{server_port}...")
        client_socket.connect((server_host, server_port))
        
        # Authentifizierung senden (Typ: vm_client)
        auth_data = json.dumps({"type": "vm_client", "secret": SHARED_SECRET_KEY})
        client_socket.sendall(len(auth_data.encode()).to_bytes(4, 'big'))
        client_socket.sendall(auth_data.encode())
        
        # Antwort abwarten
        response = client_socket.recv(1024)
        if response == b"AUTH_OK":
            print(f"[{CLIENT_NAME}] Authentifizierung erfolgreich.")
        else:
            print(f"[{CLIENT_NAME}] Authentifizierung fehlgeschlagen: {response.decode()}")
            client_socket.close()
            return None

        # Wenn Authentifizierung ok, Initialdaten der VM senden
        local_ip = get_local_ip()
        initial_data = json.dumps({"name": CLIENT_NAME, "ip": local_ip})
        
        message_length = len(initial_data.encode('utf-8'))
        client_socket.sendall(message_length.to_bytes(4, 'big'))
        client_socket.sendall(initial_data.encode('utf-8'))
        
        print(f"[{CLIENT_NAME}] Verbunden und authentifiziert mit dem Server.")
        return client_socket
    except ConnectionRefusedError:
        print(f"[{CLIENT_NAME}] Verbindung abgelehnt. Server möglicherweise nicht aktiv oder Firewall blockiert.")
        return None
    except Exception as e:
        print(f"[{CLIENT_NAME}] Fehler bei der Verbindung: {e}")
        return None

def main():
    """Hauptfunktion des VM-Clients."""
    print(f"[{CLIENT_NAME}] VM Client gestartet.")
    while True:
        sock = connect_to_server(SERVER_HOST, SERVER_PORT)
        
        if sock:
            try:
                sock.settimeout(5)
                while True:
                    try:
                        data = sock.recv(1024)
                        if not data:
                            print(f"[{CLIENT_NAME}] Server hat Verbindung geschlossen.")
                            break
                    except socket.timeout:
                        pass
                    
                    time.sleep(1)

            except ConnectionResetError:
                print(f"[{CLIENT_NAME}] Verbindung zum Server unerwartet getrennt.")
            except Exception as e:
                print(f"[{CLIENT_NAME}] Fehler während der Kommunikation: {e}")
            finally:
                if sock:
                    sock.close()
                print(f"[{CLIENT_NAME}] Verbindung geschlossen. Versuche Neuverbindung in 5 Sekunden...")
                time.sleep(5)
        else:
            print(f"[{CLIENT_NAME}] Keine Verbindung. Versuche Neuverbindung in 10 Sekunden...")
            time.sleep(10)

if __name__ == "__main__":
    main()
