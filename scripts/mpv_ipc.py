"""Bounded JSON IPC for development MPV proofs (no third-party dependencies)."""
import json
import socket
import time


class MPVIPC:
    def __init__(self, connection, timeout=15):
        self.connection = connection
        self.timeout = timeout
        self.buffer = b''
        self.request_id = 0
        self.events = []

    def _message(self, deadline):
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('MPV IPC response deadline expired')
            self.connection.settimeout(remaining)
            chunk = self.connection.recv(65536)
            if not chunk:
                raise EOFError('MPV closed its IPC connection')
            self.buffer += chunk
            if len(self.buffer) > 4 * 1024 * 1024:
                raise ValueError('MPV IPC message exceeds 4 MiB')
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line)

    def command(self, *arguments):
        self.request_id += 1
        request_id = self.request_id
        self.connection.settimeout(self.timeout)
        self.connection.sendall((json.dumps({'command': arguments, 'request_id': request_id}) + '\n').encode())
        deadline = time.monotonic() + self.timeout
        while True:
            message = self._message(deadline)
            if 'event' in message:
                self.events.append(message)
            elif message.get('request_id') == request_id:
                if message.get('error') != 'success':
                    raise RuntimeError('MPV command failed: ' + json.dumps(message))
                return message.get('data')

    def wait_event(self, event):
        deadline = time.monotonic() + self.timeout
        while True:
            for index, message in enumerate(self.events):
                if message.get('event') == event:
                    return self.events.pop(index)
                if message.get('event') == 'end-file' and message.get('reason') == 'error':
                    raise RuntimeError('MPV failed to load file: ' + json.dumps(message))
            message = self._message(deadline)
            if 'event' in message:
                self.events.append(message)


def connect(path, process, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('MPV exited before IPC became available')
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            connection.settimeout(max(0.001, deadline - time.monotonic()))
            connection.connect(str(path))
            return MPVIPC(connection, timeout)
        except (FileNotFoundError, ConnectionRefusedError):
            connection.close()
            time.sleep(0.02)
        except BaseException:
            connection.close()
            raise
    raise TimeoutError('MPV IPC socket did not become available')
