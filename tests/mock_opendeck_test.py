#!/usr/bin/env python3
"""
Mock OpenDeck / Stream Deck WebSocket server test for macos-media plugin.
Implements a minimal RFC 6455 WebSocket server in pure Python standard library.
"""

import sys
import os
import socket
import hashlib
import base64
import json
import struct
import subprocess
import time

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def create_ws_accept(sec_key):
    digest = hashlib.sha1((sec_key + WS_GUID).encode('utf-8')).digest()
    return base64.b64encode(digest).decode('utf-8')

def send_frame(sock, text):
    payload = text.encode('utf-8')
    length = len(payload)
    header = bytearray([0x81]) # FIN + text opcode
    if length <= 125:
        header.append(length)
    elif length <= 65535:
        header.append(126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", length))
    sock.sendall(header + payload)

def read_frame(sock):
    header = sock.recv(2)
    if not header or len(header) < 2:
        return None
    b1, b2 = header[0], header[1]
    is_masked = (b2 & 0x80) != 0
    payload_len = b2 & 0x7F

    if payload_len == 126:
        ext = sock.recv(2)
        payload_len = struct.unpack("!H", ext)[0]
    elif payload_len == 127:
        ext = sock.recv(8)
        payload_len = struct.unpack("!Q", ext)[0]

    mask = sock.recv(4) if is_masked else None
    data = bytearray()
    while len(data) < payload_len:
        chunk = sock.recv(payload_len - len(data))
        if not chunk:
            break
        data.extend(chunk)

    if is_masked and mask:
        unmasked = bytearray(len(data))
        for i in range(len(data)):
            unmasked[i] = data[i] ^ mask[i % 4]
        return unmasked.decode('utf-8')
    return data.decode('utf-8')

def main():
    print("=== Running Mock OpenDeck WebSocket Integration Test ===")
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_sock.bind(('127.0.0.1', 0))
    server_sock.listen(1)
    port = server_sock.getsockname()[1]
    print(f"Mock OpenDeck listening on port {port}")

    binary_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "macos-media"))
    test_uuid = "test-plugin-uuid-999"
    reg_event = "registerPlugin"

    proc = subprocess.Popen([
        binary_path,
        "-port", str(port),
        "-pluginUUID", test_uuid,
        "-registerEvent", reg_event,
        "-info", "{}"
    ])

    try:
        server_sock.settimeout(5.0)
        client_sock, addr = server_sock.accept()
        print(f"Plugin connected from {addr}")

        # HTTP Handshake
        request = client_sock.recv(2048).decode('utf-8')
        sec_key = None
        for line in request.split("\r\n"):
            if line.lower().startswith("sec-websocket-key:"):
                sec_key = line.split(":", 1)[1].strip()
                break

        assert sec_key is not None, "Failed to find Sec-WebSocket-Key in handshake"
        accept_key = create_ws_accept(sec_key)
        handshake_resp = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept_key}\r\n\r\n"
        )
        client_sock.sendall(handshake_resp.encode('utf-8'))
        print("WebSocket handshake completed")

        # Step 1: Verify Registration Message
        reg_frame = read_frame(client_sock)
        assert reg_frame is not None, "Failed to receive registration frame"
        reg_data = json.loads(reg_frame)
        print(f"Received registration: {reg_data}")
        assert reg_data.get("event") == reg_event, f"Expected event '{reg_event}', got '{reg_data.get('event')}'"
        assert reg_data.get("uuid") == test_uuid, f"Expected uuid '{test_uuid}', got '{reg_data.get('uuid')}'"
        print("✓ Plugin registration verified")

        # Step 2: Send willAppear event
        context_id = "mock-key-context-1"
        will_appear = {
            "event": "willAppear",
            "action": "com.toumorokoshi.macosmedia.playpause",
            "context": context_id,
            "device": "mock-streamdeck-1",
            "payload": {
                "settings": {},
                "state": 0
            }
        }
        send_frame(client_sock, json.dumps(will_appear))
        print("Sent willAppear event")

        # Step 3: Expect setState response
        client_sock.settimeout(3.0)
        state_frame = read_frame(client_sock)
        assert state_frame is not None, "Failed to receive setState frame"
        state_data = json.loads(state_frame)
        print(f"Received state update: {state_data}")
        assert state_data.get("event") == "setState", f"Expected event 'setState', got '{state_data.get('event')}'"
        assert state_data.get("context") == context_id, f"Expected context '{context_id}'"
        assert "state" in state_data.get("payload", {}), "Missing state in payload"
        print("✓ Initial state synchronization verified")

        # Step 4: Send keyDown event (Play/Pause)
        key_down = {
            "event": "keyDown",
            "action": "com.toumorokoshi.macosmedia.playpause",
            "context": context_id,
            "device": "mock-streamdeck-1",
            "payload": {
                "settings": {},
                "state": 0
            }
        }
        send_frame(client_sock, json.dumps(key_down))
        print("Sent keyDown event (Play/Pause)")
        time.sleep(0.5)

        # Step 5: Send willDisappear event
        will_disappear = {
            "event": "willDisappear",
            "action": "com.toumorokoshi.macosmedia.playpause",
            "context": context_id,
            "device": "mock-streamdeck-1"
        }
        send_frame(client_sock, json.dumps(will_disappear))
        print("Sent willDisappear event")

        print("✓ All protocol assertions passed successfully!")

    finally:
        try:
            client_sock.close()
        except Exception:
            pass
        server_sock.close()
        proc.terminate()
        try:
            proc.wait(timeout=2.0)
        except Exception:
            proc.kill()

if __name__ == "__main__":
    main()
