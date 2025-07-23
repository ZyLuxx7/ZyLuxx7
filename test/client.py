import socket
import time
import os
import struct
import json
import subprocess # Behalten wir für zukünftige Nutzung wie Systembefehle ausführen

# --- Konfiguration für Service Discovery (Multicast) ---
# Diese Multicast-Gruppe und dieser Port werden verwendet, um den Server zu finden.
# Sie müssen NICHT angepasst werden, es sei denn, Sie haben spezielle Netzwerkanforderungen.
MCAST_GRP = '224.1.1.1' # Standard-Multicast-Gruppe
MCAST_PORT = 5007       # Port für Multicast-Beacons (muss auf Client und Server gleich sein)

# Dieser TCP-Port wird für die eigentliche Steuerungsverbindung zum Server verwendet.
# Er muss NICHT angepasst werden, es sei denn, Sie möchten einen anderen Port nutzen.
SERVER_TCP_PORT = 12345 # Der Port für die eigentliche TCP-Verbindung (muss auf Server und Client gleich sein)

# Ermittelt den Namen des Computers, auf dem der Client läuft.
# Dies wird dem Server gemeldet, um die VM in der GUI zu identifizieren.
CLIENT_NAME = os.environ.get('COMPUTERNAME', 'UnknownVM')

def get_local_ip():
    """
    Versucht, die lokale IP-Adresse des Hosts zu ermitteln.
    Dies ist notwendig, da die VM dem Server ihre eigene IP mitteilen muss.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Trick, um die eigene IP zu finden: Verbindet sich mit einer bekannten,
        # nicht-routbaren Adresse, um die beste lokale Schnittstelle zu ermitteln.
        # Es werden keine Daten gesendet.
        s.connect(('10.255.255.255', 1))
        IP = s.getsockname()[0]
    except Exception:
        IP = '127.0.0.1' # Fallback-Adresse, falls IP-Bestimmung fehlschlägt
    finally:
        s.close()
    return IP

def discover_server():
    """
    Lauscht auf Multicast-Beacons, die vom Haupt-PC-Server gesendet werden,
    um dessen IP-Adresse und den TCP-Port für die eigentliche Verbindung zu finden.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    
    try:
        # Bindet das Socket an alle verfügbaren Netzwerkschnittstellen auf dem Multicast-Port.
        sock.bind(('', MCAST_PORT))
    except OSError as e:
        print(f"[{CLIENT_NAME}] Fehler beim Binden des Sockets an Port {MCAST_PORT}: {e}")
        print(f"[{CLIENT_NAME}] Dies könnte bedeuten, dass der Port bereits belegt ist oder die Firewall ihn blockiert. Versuche erneut...")
        # Wichtig für Windows: Manchmal hilft SO_REUSEPORT bei schnellen Restarts, ist aber nicht immer verfügbar
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            sock.bind(('', MCAST_PORT)) # Erneuter Versuch nach Hinzufügen von SO_REUSEPORT
        except AttributeError:
            pass # SO_REUSEPORT nicht verfügbar
        except OSError as e_retry:
            print(f"[{CLIENT_NAME}] Erneuter Fehler beim Binden des Sockets: {e_retry}. Dienst kann Multicast nicht empfangen.")
            return None, None # Wenn Bindung fehlschlägt, können wir den Server nicht finden

    # Tritt der Multicast-Gruppe bei, um Beacons empfangen zu können.
    # INADDR_ANY bedeutet, dass auf allen lokalen Schnittstellen gelauscht wird.
    mreq = struct.pack("4sl", socket.inet_aton(MCAST_GRP), socket.INADDR_ANY)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    
    sock.settimeout(5) # Setzt ein Timeout für den Empfang von Daten.
                       # Wenn innerhalb von 5 Sekunden kein Beacon kommt, wird eine Exception geworfen.
    
    print(f"[{CLIENT_NAME}] Starte Server-Erkennung auf {MCAST_GRP}:{MCAST_PORT}...")
    while True:
        try:
            # Empfängt Daten von der Multicast-Gruppe.
            data, server_address = sock.recvfrom(1024) 
            message = data.decode('utf-8')
            print(f"[{CLIENT_NAME}] Beacon empfangen von {server_address[0]}: {message}")
            
            try:
                # Versucht, die empfangene Nachricht als JSON zu parsen.
                # Der Server sollte seine Informationen in diesem Format senden.
                beacon_info = json.loads(message)
                if beacon_info.get("type") == "vm_control_beacon":
                    server_ip = beacon_info.get("ip")
                    server_port = beacon_info.get("port")
                    if server_ip and server_port:
                        print(f"[{CLIENT_NAME}] Server gefunden: {server_ip}:{server_port}")
                        sock.close() # Schließt das Multicast-Socket, sobald der Server gefunden wurde.
                        return server_ip, server_port
            except json.JSONDecodeError:
                print(f"[{CLIENT_NAME}] Ungültiges Beacon-Format (kein JSON oder falsches Schema): {message}")
            
        except socket.timeout:
            # Das Timeout wurde erreicht, es wurde kein Beacon empfangen.
            print(f"[{CLIENT_NAME}] Warte auf Server-Beacon (Timeout).")
        except Exception as e:
            # Allgemeine Fehlerbehandlung beim Empfang des Beacons.
            print(f"[{CLIENT_NAME}] Fehler bei der Server-Erkennung: {e}")
        time.sleep(1) # Kurze Pause, um CPU-Auslastung zu reduzieren.

def connect_to_server(server_ip, server_port):
    """
    Stellt eine TCP-Verbindung zum gefundenen Haupt-PC-Server her.
    """
    client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        print(f"[{CLIENT_NAME}] Versuche TCP-Verbindung zu {server_ip}:{server_port}...")
        client_socket.connect((server_ip, server_port))
        print(f"[{CLIENT_NAME}] Verbunden mit dem Server.")

        # Sendet den VM-Namen und die lokale IP der VM als JSON an den Server.
        # Dies ist die erste Nachricht nach dem Verbindungsaufbau, damit der Server
        # weiß, welche VM sich verbunden hat.
        local_ip = get_local_ip()
        initial_data = json.dumps({"name": CLIENT_NAME, "ip": local_ip})
        
        # Wichtig: Sendet zuerst die Länge der JSON-Nachricht (als 4 Bytes im "Big-Endian"-Format).
        # Dadurch weiß der Server, wie viele Bytes er für die komplette JSON-Nachricht lesen muss.
        message_length = len(initial_data.encode('utf-8'))
        client_socket.sendall(message_length.to_bytes(4, 'big'))
        client_socket.sendall(initial_data.encode('utf-8'))

        return client_socket
    except ConnectionRefusedError:
        print(f"[{CLIENT_NAME}] Verbindung abgelehnt. Server möglicherweise nicht bereit auf TCP-Port.")
        return None
    except Exception as e:
        print(f"[{CLIENT_NAME}] Fehler bei der TCP-Verbindung: {e}")
        return None

def main():
    """
    Die Hauptschleife des VM-Clients.
    Versucht, den Server zu finden und eine dauerhafte Verbindung aufrechtzuerhalten.
    """
    print(f"[{CLIENT_NAME}] VM Client gestartet.")
    while True:
        server_ip, server_port = None, None
        try:
            # Startet die Server-Erkennung.
            server_ip, server_port = discover_server() 
        except Exception as e:
            print(f"[{CLIENT_NAME}] Fehler während der Server-Erkennung im Hauptloop: {e}")

        sock = None
        if server_ip and server_port:
            # Wenn ein Server gefunden wurde, versucht der Client, eine TCP-Verbindung aufzubauen.
            sock = connect_to_server(server_ip, SERVER_TCP_PORT) # Nutze SERVER_TCP_PORT für die TCP-Verbindung
        
        if sock:
            try:
                # Hier würde später die Hauptlogik für Bildschirm-Streaming und
                # Eingabe-Injektion implementiert werden.
                # Der Client würde Befehle vom Server empfangen (z.B. "starte Streaming", "Maus bewegen")
                # und die entsprechenden Aktionen auf der VM ausführen.
                while True:
                    # Für den Moment sorgt ein kleines sleep dafür, dass der Client aktiv bleibt,
                    # ohne die CPU unnötig zu belasten.
                    # Später würde hier eine Schleife sein, die Daten vom Server liest.
                    # Beispiel: data = sock.recv(4096)
                    # if not data: break # Verbindung geschlossen
                    # process_server_command(data) # Funktion zur Verarbeitung von Serverbefehlen
                    time.sleep(0.5) 
            except ConnectionResetError:
                print(f"[{CLIENT_NAME}] Verbindung zum Server unerwartet getrennt.")
            except Exception as e:
                print(f"[{CLIENT_NAME}] Fehler während der Kommunikation: {e}")
            finally:
                if sock:
                    sock.close() # Schließt das Socket, wenn die Verbindung getrennt wird oder ein Fehler auftritt.
                print(f"[{CLIENT_NAME}] Verbindung geschlossen. Versuche Neuverbindung...")
                time.sleep(5) # Wartet 5 Sekunden, bevor ein erneuter Verbindungsversuch gestartet wird.
        else:
            print(f"[{CLIENT_NAME}] Kein aktiver Server gefunden oder Verbindung fehlgeschlagen. Versuche Server-Erkennung erneut in 10 Sekunden...")
            time.sleep(10) # Längere Pause, bevor die Server-Erkennung wiederholt wird.

if __name__ == "__main__":
    main()
