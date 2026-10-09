import json
import socket
import threading
import unittest

from mpv_ipc import MPVIPC


class IPCProtocolTests(unittest.TestCase):
    def setUp(self):
        self.client_socket, self.server_socket = socket.socketpair()
        self.addCleanup(self.client_socket.close)
        self.addCleanup(self.server_socket.close)
        self.client = MPVIPC(self.client_socket, timeout=0.2)

    def respond(self, messages):
        def server():
            request = json.loads(self.server_socket.recv(65536))
            payload = b''.join((json.dumps(dict(message, **({'request_id': request['request_id']}
                              if 'error' in message else {}))) + '\n').encode() for message in messages)
            # Split a message across reads, as real stream sockets may do.
            self.server_socket.sendall(payload[:5])
            self.server_socket.sendall(payload[5:])
        thread = threading.Thread(target=server)
        thread.start()
        self.addCleanup(thread.join)

    def test_command_keeps_events_and_handles_fragmented_messages(self):
        self.respond([{'event': 'file-loaded'}, {'error': 'success', 'data': [{'id': 7}]},
                      {'event': 'end-file', 'reason': 'eof'}])
        self.assertEqual(self.client.command('get_property', 'track-list'), [{'id': 7}])
        self.assertEqual(self.client.wait_event('file-loaded'), {'event': 'file-loaded'})
        self.assertEqual(self.client.wait_event('end-file')['reason'], 'eof')

    def test_command_error_is_not_treated_as_success(self):
        self.respond([{'error': 'property unavailable'}])
        with self.assertRaisesRegex(RuntimeError, 'property unavailable'):
            self.client.command('get_property', 'track-list')

    def test_eof_does_not_spin(self):
        self.server_socket.close()
        with self.assertRaises(EOFError):
            self.client.wait_event('file-loaded')

    def test_missing_event_has_bounded_deadline(self):
        with self.assertRaises(TimeoutError):
            self.client.wait_event('file-loaded')

    def test_load_error_stops_waiting(self):
        self.server_socket.sendall(b'{"event":"end-file","reason":"error"}\n')
        with self.assertRaisesRegex(RuntimeError, 'failed to load'):
            self.client.wait_event('file-loaded')


if __name__ == '__main__':
    unittest.main()
