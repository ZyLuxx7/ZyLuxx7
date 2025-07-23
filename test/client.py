import socket
import time
import os
import json
import subprocess
# Importe für Screenshot und Eingabe-Injektion kommen hier später hinzu

# --- Konfiguration für Serveo ---
# ERSETZEN SIE 'YOUR_SERVEO_SUBDOMAIN' DURCH IHRE TATSÄCHLICHE SUBDOMAIN BEI SERVEO
# Beispiel: 'myvmcontrol.serveo.net'
SERVER_HOSTNAME = 'your_chosen_name.serveo.net' # <-- HIER ANPASSEN!
SERVEO_PORT = 12345 # Muss mit LOCAL_SERVER_PORT in main_app.py und SSH-Tunnel übereinstimmen

CLIENT_NAME = os.environ.get('COMPUTERNAME', 'UnknownVM')

def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('10.255.255.255', 1))
        IP = s.getsockname()[0]
    except Exception:
        IP = '127.0.0.1'
    finally:
        s.close()
    return IP

def connect_to_server():
    """Versucht, sich mit dem Haupt-PC-Server über die Serveo-Adresse zu verbinden."""
    client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        print(f"[{CLIENT_NAME}] Versuche Verbindung zu Serveo: {SERVER_HOSTNAME}:{SERVEO_PORT}...")
        client_socket.connect((SERVER_HOSTNAME, SERVEO_PORT))
        print(f"[{CLIENT_NAME}] Verbunden mit dem Serveo-Relay.")

        local_ip = get_local_ip()
        initial_data = json.dumps({"name": CLIENT_NAME, "ip": local_ip})
        
        message_length = len(initial_data.encode('utf-8'))
        client_socket.sendall(message_length.to_bytes(4, 'big'))
        client_socket.sendall(initial_data.encode('utf-8'))
        
        client_socket.sendall(b"heartbeat") # Sende einen ersten Keep-Alive

        return client_socket
    except socket.gaierror:
        print(f"[{CLIENT_NAME}] Fehler: Hostname '{SERVER_HOSTNAME}' konnte nicht aufgelöst werden. Serveo ist möglicherweise nicht erreichbar oder Subdomain falsch.")
        return None
    except ConnectionRefusedError:
        print(f"[{CLIENT_NAME}] Verbindung zu Serveo/Server abgelehnt. Serveo-Tunnel auf Haupt-PC aktiv?")
        return None
    except Exception as e:
        print(f"[{CLIENT_NAME}] Fehler bei der Serveo-Verbindung: {e}")
        return None

def main():
    print(f"[{CLIENT_NAME}] VM Client gestartet.")
    while True:
        sock = connect_to_server()
        
        if sock:
            try:
                sock.settimeout(5)
                while True:
                    try:
                        data = sock.recv(1024)
                        if not data:
                            print(f"[{CLIENT_NAME}] Serveo/Server hat Verbindung geschlossen.")
                            break
                    except socket.timeout:
                        pass

                    try:
                        sock.sendall(b"heartbeat") 
                    except BrokenPipeError:
                        print(f"[{CLIENT_NAME}] Verbindung zu Serveo/Server getrennt (Broken Pipe).")
                        break
                    except Exception as e:
                        print(f"[{CLIENT_NAME}] Fehler beim Senden des Heartbeats: {e}")
                        break
                        
                    time.sleep(1)

            except ConnectionResetError:
                print(f"[{CLIENT_NAME}] Verbindung zu Serveo/Server unerwartet getrennt.")
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
