#!/usr/bin/python3
"""Host-CID-only vsock streams; no workload API translation or command endpoint."""
import concurrent.futures
import http.client
import json
import os
import select
import socket
import threading

INCUS_SOCKET = '/var/lib/incus/unix.socket'


def host_peer(peer):
    return peer[0] == 2


def incus_health():
    connection = http.client.HTTPConnection('localhost', timeout=2)
    connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.sock.settimeout(2)
    connection.sock.connect(INCUS_SOCKET)
    try:
        connection.request('GET', '/internal/ready')
        ready = connection.getresponse()
        ready.read(1048576)
        if ready.status != 200:
            raise RuntimeError('Incus startup tasks have not completed')
        connection.request('GET', '/1.0')
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError('Incus is unavailable')
        metadata = json.loads(response.read(1048576))['metadata']
        return {
            'protocol_version': 1,
            'incus_version': metadata['environment']['server_version'],
            'api_extensions': metadata['api_extensions'],
            'kvm': os.access('/dev/kvm', os.R_OK | os.W_OK),
        }
    finally:
        connection.close()


def relay(client):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as incus:
        incus.connect(INCUS_SOCKET)
        # Each direction handles partial writes/backpressure in sendall; no HTTP parsing.
        def pump(source, target):
            try:
                while True:
                    data = source.recv(65536)
                    if not data:
                        target.shutdown(socket.SHUT_WR)
                        return
                    target.sendall(data)
            except OSError:
                for stream in (source, target):
                    try:
                        stream.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        thread = threading.Thread(target=pump, args=(client, incus))
        thread.start()
        pump(incus, client)
        thread.join()


def health(client):
    client.settimeout(3)
    request = bytearray()
    while b'\r\n\r\n' not in request:
        chunk = client.recv(4096)
        if not chunk or len(request) + len(chunk) > 16384:
            return
        request.extend(chunk)
    if not request.startswith(b'GET /health HTTP/1.1\r\n'):
        code, result = '404 Not Found', {'error': 'unknown health route'}
    else:
        try:
            result = incus_health()
            code = '200 OK'
        except (OSError, ValueError, KeyError, RuntimeError) as error:
            code, result = '503 Service Unavailable', {'error': str(error)}
    body = json.dumps(result, separators=(',', ':')).encode()
    client.sendall(f'HTTP/1.1 {code}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode() + body)


def serve(port, handler):
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as listener:
        listener.bind((socket.VMADDR_CID_ANY, port))
        listener.listen(128)
        slots = threading.BoundedSemaphore(128)
        def handle(client):
            try:
                with client:
                    handler(client)
            except (OSError, ValueError):
                pass
            finally:
                slots.release()
        with concurrent.futures.ThreadPoolExecutor(max_workers=128) as pool:
            while True:
                client, peer = listener.accept()
                if not host_peer(peer) or not slots.acquire(blocking=False):
                    client.close()
                    continue
                pool.submit(handle, client)


if __name__ == '__main__':
    threading.Thread(target=serve, args=(8443, relay), daemon=True).start()
    serve(8444, health)
