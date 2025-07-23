import socket
import time
import os
import struct
import json
import subprocess
# Importe für Screenshot und Eingabe-Injektion (kommen später hinzu)
# import pyautogui # Für Screenshots (Windows) - muss auf der VM installiert werden
# import pynput.mouse # Für Mauseingabe - muss auf der VM installiert werden
# import pynput.keyboard # Für Tastatureingabe - muss auf der VM installiert werden

# --- Konfiguration für Service Discovery (Multicast) ---
MCAST_GRP = '224.1.1.1'
MCAST_PORT = 5007
SERVER_TCP_PORT = 12345 # Muss mit main_app.py übereinstimmen

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

def discover_server():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    
    try:
        sock.bind(('', MCAST_PORT))
    except OSError as e:
        print(f"[{CLIENT_NAME}] Fehler beim Binden des Sockets an Port {MCAST_PORT}: {e}")
        print(f"[{CLIENT_NAME}] Dies könnte bedeuten, dass der Port bereits belegt ist. Versuche erneut...")
        time.sleep(2) # Kurze Pause, dann Haupt-Loop-Retry
        return None, None

    mreq = struct.pack("4sl", socket.inet_aton(MCAST_GRP), socket.INADDR_ANY)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    
    sock.settimeout(5) # Timeout für den Empfang
    
    print(f"[{CLIENT_NAME}] Starte Server-Erkennung auf {MCAST_GRP}:{MCAST_PORT}...")
    while True:
        try:
            data, server_address = sock.recvfrom(1024)
            message = data.decode('utf-8')
            # print(f"[{CLIENT_NAME}] Beacon empfangen von {server_address[0]}: {message}") # Für Debugging
            
            try:
                beacon_info = json.loads(message)
                if beacon_info.get("type") == "vm_control_beacon":
                    server_ip = beacon_info.get("ip")
                    server_port = beacon_info.get("port")
                    if server_ip and server_port:
                        print(f"[{CLIENT_NAME}] Server gefunden: {server_ip}:{server_port}")
                        sock.close()
                        return server_ip, server_port
            except json.JSONDecodeError:
                print(f"[{CLIENT_NAME}] Ungültiges Beacon-Format: {message}")
            
        except socket.timeout:
            print(f"[{CLIENT_NAME}] Warte auf Server-Beacon (Timeout).")
        except Exception as e:
            print(f"[{CLIENT_NAME}] Fehler bei der Server-Erkennung: {e}")
        time.sleep(1)

def connect_to_server(server_ip, server_port):
    client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        print(f"[{CLIENT_NAME}] Versuche TCP-Verbindung zu {server_ip}:{server_port}...")
        client_socket.connect((server_ip, server_port))
        print(f"[{CLIENT_NAME}] Verbunden mit dem Server.")

        local_ip = get_local_ip()
        initial_data = json.dumps({"name": CLIENT_NAME, "ip": local_ip})
        
        message_length = len(initial_data.encode('utf-8'))
        client_socket.sendall(message_length.to_bytes(4, 'big'))
        client_socket.sendall(initial_data.encode('utf-8'))
        
        # Sende einen ersten Keep-Alive, um den Server-Status zu aktualisieren
        client_socket.sendall(b"heartbeat") 

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
        server_ip, server_port = None, None
        try:
            server_ip, server_port = discover_server()
        except Exception as e:
            print(f"[{CLIENT_NAME}] Fehler während der Server-Erkennung im Hauptloop: {e}")

        sock = None
        if server_ip and server_port:
            sock = connect_to_server(server_ip, SERVER_TCP_PORT)
        
        if sock:
            try:
                # Kommunikation mit dem Server
                sock.settimeout(5) # Timeout für Empfang, um Heartbeats zu senden
                while True:
                    # In einer vollständigen Implementierung würden hier Befehle vom Server empfangen
                    # z.B. "START_SCREEN_STREAM", "MOUSE_MOVE", etc.
                    try:
                        data = sock.recv(1024) # Empfange Befehle
                        if not data:
                            print(f"[{CLIENT_NAME}] Server hat Verbindung geschlossen.")
                            break
                        # print(f"[{CLIENT_NAME}] Befehl vom Server empfangen: {data.decode()}")
                        # TODO: Hier Befehle verarbeiten
                        # Beispiel: if data == b"GET_SCREEN": send_screenshot(sock)
                        # Beispiel: if data.startswith(b"MOUSE_MOVE:"): handle_mouse_move(data)
                    except socket.timeout:
                        # Timeout ist ok, Client kann Heartbeat senden
                        pass
                    except ConnectionResetError:
                        print(f"[{CLIENT_NAME}] Server hat die Verbindung unerwartet getrennt.")
                        break

                    # Sende regelmäßig einen Keep-Alive/Heartbeat an den Server
                    # damit der Server weiß, dass der Client noch aktiv ist.
                    try:
                        sock.sendall(b"heartbeat") 
                    except BrokenPipeError:
                        print(f"[{CLIENT_NAME}] Verbindung zum Server getrennt (Broken Pipe).")
                        break
                    except Exception as e:
                        print(f"[{CLIENT_NAME}] Fehler beim Senden des Heartbeats: {e}")
                        break # Verbindung wahrscheinlich tot
                        
                    time.sleep(1) # Kurze Pause

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
            print(f"[{CLIENT_NAME}] Kein aktiver Server gefunden oder Verbindung fehlgeschlagen. Versuche Server-Erkennung erneut in 10 Sekunden...")
            time.sleep(10)

if __name__ == "__main__":
    main()
