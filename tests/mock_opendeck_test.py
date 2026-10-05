#!/usr/bin/env python3
"""
Mock OpenDeck / Stream Deck WebSocket server test for yft sandbox plugin.
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
import tempfile
import threading
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

class WSMessageQueue:
    def __init__(self, sock):
        self.sock = sock
        self.queue = []

    def wait_for(self, predicate, timeout=4.0):
        deadline = time.time() + timeout
        for i, msg in enumerate(self.queue):
            if predicate(msg):
                return self.queue.pop(i)

        while time.time() < deadline:
            remaining = max(0.1, deadline - time.time())
            self.sock.settimeout(remaining)
            try:
                frame = read_frame(self.sock)
                if not frame:
                    continue
                msg = json.loads(frame)
                if predicate(msg):
                    return msg
                self.queue.append(msg)
            except socket.timeout:
                break
        raise TimeoutError(f"Timed out waiting for message satisfying condition. Received queue: {self.queue}")

def accept_ws(server_sock):
    """Accepts a single WebSocket client and completes the handshake. Returns (socket, request line)."""
    client_sock, _ = server_sock.accept()
    request = client_sock.recv(2048).decode('utf-8')
    sec_key = None
    for line in request.split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            sec_key = line.split(":", 1)[1].strip()
            break
    assert sec_key is not None, "Failed to find Sec-WebSocket-Key in handshake"
    handshake_resp = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {create_ws_accept(sec_key)}\r\n\r\n"
    )
    client_sock.sendall(handshake_resp.encode('utf-8'))
    return client_sock, request.split("\r\n", 1)[0]

class MockTeams:
    """Minimal Microsoft Teams third-party API (protocol 2.0.0) server."""

    def __init__(self):
        self.server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server_sock.bind(('127.0.0.1', 0))
        self.server_sock.listen(1)
        self.port = self.server_sock.getsockname()[1]
        self.state = {"isInMeeting": True, "isMuted": True, "isVideoOn": False}
        self.request_line = None
        self.received_actions = []
        threading.Thread(target=self._serve, daemon=True).start()

    def _send_update(self, sock):
        send_frame(sock, json.dumps({
            "meetingUpdate": {
                "meetingState": self.state,
                "meetingPermissions": {"canToggleMute": True, "canToggleVideo": True},
            }
        }))

    def _serve(self):
        sock, self.request_line = accept_ws(self.server_sock)
        self._send_update(sock)
        while True:
            try:
                sock.settimeout(None)
                frame = read_frame(sock)
            except OSError:
                return
            if frame is None:
                return
            req = json.loads(frame)
            self.received_actions.append(req.get("action"))
            if req.get("action") == "toggle-video":
                self.state["isVideoOn"] = not self.state["isVideoOn"]
            elif req.get("action") == "toggle-mute":
                self.state["isMuted"] = not self.state["isMuted"]
            send_frame(sock, json.dumps({"requestId": req.get("requestId"), "response": "Success"}))
            self._send_update(sock)

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

    mock_teams = MockTeams()
    token_dir = tempfile.TemporaryDirectory()
    env = dict(os.environ)
    env["YFT_TEAMS_API_URL"] = f"ws://127.0.0.1:{mock_teams.port}"
    env["YFT_TEAMS_TOKEN_PATH"] = os.path.join(token_dir.name, "teams_token")
    print(f"Mock Teams API listening on port {mock_teams.port}")

    proc = subprocess.Popen([
        binary_path,
        "-port", str(port),
        "-pluginUUID", test_uuid,
        "-registerEvent", reg_event,
        "-info", "{}"
    ], env=env)

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

        mq = WSMessageQueue(client_sock)

        # Step 1: Verify Registration Message
        reg_data = mq.wait_for(lambda m: m.get("event") == reg_event)
        print(f"Received registration: {reg_data}")
        assert reg_data.get("uuid") == test_uuid, f"Expected uuid '{test_uuid}', got '{reg_data.get('uuid')}'"
        print("✓ Plugin registration verified")

        # Step 2: Test Play/Pause Action
        context_media = "mock-key-context-media"
        will_appear_media = {
            "event": "willAppear",
            "action": "com.toumorokoshi.yftsandbox.playpause",
            "context": context_media,
            "device": "mock-streamdeck-1",
            "payload": {
                "settings": {},
                "state": 0
            }
        }
        send_frame(client_sock, json.dumps(will_appear_media))
        print("Sent willAppear for playpause")

        state_data = mq.wait_for(lambda m: m.get("event") == "setState" and m.get("context") == context_media)
        print(f"Received media state update: {state_data}")
        print("✓ Media initial state synchronization verified")

        # Step 3: Test Mic Mute Action (0% / 100%)
        context_mic = "mock-key-context-mic"
        will_appear_mic = {
            "event": "willAppear",
            "action": "com.toumorokoshi.yftsandbox.micmute",
            "context": context_mic,
            "device": "mock-streamdeck-1",
            "payload": {
                "settings": {},
                "state": 0
            }
        }
        send_frame(client_sock, json.dumps(will_appear_mic))
        print("Sent willAppear for micmute")

        # Plugin should send setState and setTitle
        mic_state = mq.wait_for(lambda m: m.get("event") == "setState" and m.get("context") == context_mic)
        mic_title = mq.wait_for(lambda m: m.get("event") == "setTitle" and m.get("context") == context_mic)
        print(f"Received mic initial state: {mic_state}, title: {mic_title}")
        assert "state" in mic_state.get("payload", {})
        assert "title" in mic_title.get("payload", {})
        print(f"✓ Mic initial state ({mic_state['payload']['state']}) & title ({mic_title['payload']['title']}) verified")

        # Step 4: Toggle mic mute via keyDown
        initial_state = mic_state['payload']['state']
        expected_toggled_state = 1 if initial_state == 0 else 0

        key_down_mic = {
            "event": "keyDown",
            "action": "com.toumorokoshi.yftsandbox.micmute",
            "context": context_mic,
            "device": "mock-streamdeck-1",
            "payload": {
                "settings": {},
                "state": 0
            }
        }
        send_frame(client_sock, json.dumps(key_down_mic))
        print("Sent keyDown for micmute")

        # Expect state and title update on mute toggle
        toggle_state = mq.wait_for(lambda m: m.get("event") == "setState" and m.get("context") == context_mic and m.get("payload", {}).get("state") == expected_toggled_state)
        toggle_title = mq.wait_for(lambda m: m.get("event") == "setTitle" and m.get("context") == context_mic)
        print(f"Received mic toggle state: {toggle_state}, title: {toggle_title}")
        assert toggle_state['payload']['state'] == expected_toggled_state
        print("✓ Mic toggle event handling verified")

        time.sleep(0.3)

        # Step 5: Toggle mic mute back to restore
        send_frame(client_sock, json.dumps(key_down_mic))
        restore_state = mq.wait_for(lambda m: m.get("event") == "setState" and m.get("context") == context_mic and m.get("payload", {}).get("state") == initial_state)
        restore_title = mq.wait_for(lambda m: m.get("event") == "setTitle" and m.get("context") == context_mic)
        print(f"Received mic restore state: {restore_state}, title: {restore_title}")
        assert restore_state['payload']['state'] == initial_state
        print("✓ Mic restore toggle verified")

        # Step 6: Send willDisappear
        will_disappear = {
            "event": "willDisappear",
            "action": "com.toumorokoshi.yftsandbox.micmute",
            "context": context_mic,
            "device": "mock-streamdeck-1"
        }
        send_frame(client_sock, json.dumps(will_disappear))
        print("Sent willDisappear event for micmute")

        # Step 7: Teams camera and mute keys reflect meeting state pushed by Teams
        context_camera = "mock-key-context-teams-camera"
        context_teams_mute = "mock-key-context-teams-mute"
        for action, ctx in [
            ("com.toumorokoshi.yftsandbox.teamscamera", context_camera),
            ("com.toumorokoshi.yftsandbox.teamsmute", context_teams_mute),
        ]:
            send_frame(client_sock, json.dumps({
                "event": "willAppear",
                "action": action,
                "context": ctx,
                "device": "mock-streamdeck-1",
                "payload": {"settings": {}, "state": 0}
            }))
        # Once the mock Teams meetingUpdate arrives, keys show in-meeting (empty title) with camera off / muted.
        for ctx in [context_camera, context_teams_mute]:
            mq.wait_for(lambda m, ctx=ctx: m.get("event") == "setTitle" and m.get("context") == ctx and m["payload"]["title"] == "")
        assert "protocol-version=2.0.0" in mock_teams.request_line, mock_teams.request_line
        print("✓ Teams keys synchronized with meeting state")

        # Step 8: Toggle Teams camera and mute via keyDown
        for action, ctx, teams_action in [
            ("com.toumorokoshi.yftsandbox.teamscamera", context_camera, "toggle-video"),
            ("com.toumorokoshi.yftsandbox.teamsmute", context_teams_mute, "toggle-mute"),
        ]:
            send_frame(client_sock, json.dumps({
                "event": "keyDown",
                "action": action,
                "context": ctx,
                "device": "mock-streamdeck-1",
                "payload": {"settings": {}, "state": 0}
            }))
            mq.wait_for(lambda m, ctx=ctx: m.get("event") == "setState" and m.get("context") == ctx and m["payload"]["state"] == 1)
            assert teams_action in mock_teams.received_actions, mock_teams.received_actions
            print(f"✓ Teams {teams_action} verified")

        print("✓ All protocol assertions passed successfully!")

    finally:
        try:
            client_sock.close()
        except Exception:
            pass
        server_sock.close()
        mock_teams.server_sock.close()
        token_dir.cleanup()
        proc.terminate()
        try:
            proc.wait(timeout=2.0)
        except Exception:
            proc.kill()

if __name__ == "__main__":
    main()
