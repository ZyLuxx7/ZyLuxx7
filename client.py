# vm_client.py (Dies ist der Code, der auf den VMs laufen wird)

import socket
import time
import os
import struct
import subprocess
import json # Für einfache Datenübertragung

# --- Konfiguration für Service Discovery (Multicast) ---
MCAST_GRP = '224.1.1.1' # Standard-Multicast-Gruppe
MCAST_PORT = 5007       # Port für Multicast-Beacons (muss auf Client und Server gleich sein)
SERVER_TCP_PORT = 12345 # Der Port für die eigentliche TCP-Verbindung (muss auf Server und Client gleich sein)

CLIENT_NAME = os.environ.get('COMPUTERNAME', 'UnknownVM')

def discover_server():
    """Lauscht auf Multicast-Beacons, um den Server zu finden."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    
    # Sicherstellen, dass das Socket an die korrekte Schnittstelle bindet
    # Dies kann komplex sein, daher zuerst an 0.0.0.0 binden und Multicast-Gruppe beitreten
    try:
        sock.bind(('', MCAST_PORT))
    except OSError as e:
        print(f"[{CLIENT_NAME}] Fehler beim Binden des Sockets an Port {MCAST_PORT}: {e}. Wahrscheinlich schon in Benutzung.")
        print(f"[{CLIENT_NAME}] Versuche mit einem anderen Socket...")
        # Erhöht die Robustheit bei schnellem Neustart
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        sock.bind(('', MCAST_PORT))


    mreq = struct.pack("4sl", socket.inet_aton(MCAST_GRP), socket.INADDR_ANY)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    
    sock.settimeout(5) # Kurzes Timeout für den Empfang
    
    print(f"[{CLIENT_NAME}] Starte Server-Erkennung auf {MCAST_GRP}:{MCAST_PORT}...")
    while True:
        try:
            data, server_address = sock.recvfrom(1024) # Buffer size 1024
            message = data.decode('utf-8')
            print(f"[{CLIENT_NAME}] Beacon empfangen von {server_address[0]}: {message}")
            
            # Der Beacon sollte die TCP-Port-Information enthalten
            try:
                beacon_info = json.loads(message)
                if beacon_info.get("type") == "vm_control_beacon":
                    server_ip = beacon_info.get("ip")
                    server_port = beacon_info.get("port")
                    if server_ip and server_port:
                        print(f"[{CLIENT_NAME}] Server gefunden: {server_ip}:{server_port}")
                        sock.close() # Schließe das Multicast-Socket
                        return server_ip, server_port
            except json.JSONDecodeError:
                print(f"[{CLIENT_NAME}] Ungültiges Beacon-Format: {message}")
            
        except socket.timeout:
            print(f"[{CLIENT_NAME}] Warte auf Server-Beacon (Timeout).")
        except Exception as e:
            print(f"[{CLIENT_NAME}] Fehler bei der Server-Erkennung: {e}")
        time.sleep(1) # Kurze Pause, bevor erneut gewartet wird

def connect_to_server(server_ip, server_port):
    """Versucht, sich mit dem Haupt-PC-Server über TCP zu verbinden."""
    client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        print(f"[{CLIENT_NAME}] Versuche TCP-Verbindung zu {server_ip}:{server_port}...")
        client_socket.connect((server_ip, server_port))
        print(f"[{CLIENT_NAME}] Verbunden mit dem Server.")

        # Sende den VM-Namen und die lokale IP der VM an den Server
        local_ip = client_socket.getsockname()[0]
        initial_data = json.dumps({"name": CLIENT_NAME, "ip": local_ip})
        client_socket.sendall(initial_data.encode('utf-8'))
        return client_socket
    except ConnectionRefusedError:
        print(f"[{CLIENT_NAME}] Verbindung abgelehnt. Server möglicherweise nicht bereit auf TCP-Port.")
        return None
    except Exception as e:
        print(f"[{CLIENT_NAME}] Fehler bei der TCP-Verbindung: {e}")
        return None

def main():
    print(f"[{CLIENT_NAME}] VM Client gestartet.")
    while True:
        server_ip, server_port = discover_server() # Zuerst Server finden
        
        sock = None
        if server_ip and server_port:
            sock = connect_to_server(server_ip, server_port)
        
        if sock:
            try:
                while True:
                    # Der Client muss aktiv bleiben, um die Verbindung zu halten
                    # Hier würden später die Screenshot- und Input-Handling-Logik implementiert
                    time.sleep(1) # Kurze Pause, um CPU zu sparen
            except ConnectionResetError:
                print(f"[{CLIENT_NAME}] Verbindung zum Server unerwartet getrennt.")
            except Exception as e:
                print(f"[{CLIENT_NAME}] Fehler während der Kommunikation: {e}")
            finally:
                if sock:
                    sock.close()
                print(f"[{CLIENT_NAME}] Verbindung geschlossen. Versuche Neuverbindung...")
                time.sleep(5) # Kurze Pause vor dem nächsten Verbindungsversuch
        else:
            print(f"[{CLIENT_NAME}] Kein aktiver Server gefunden oder Verbindung fehlgeschlagen. Versuche Server-Erkennung erneut...")
            time.sleep(10) # Längere Pause, bevor die Erkennung wiederholt wird

if __name__ == "__main__":
    main()
