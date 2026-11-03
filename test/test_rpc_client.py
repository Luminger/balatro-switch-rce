"""Offline RPC framing tests; never open a network connection."""
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import rpc


class ClientTests(unittest.TestCase):
    def test_raw_chunk_and_half_close(self):
        with mock.patch.object(rpc.socket, "create_connection") as connect:
            conn = connect.return_value.__enter__.return_value
            conn.recv.side_effect = [b"-> 4\n", b""]
            result = rpc.send("127.0.0.1", 9026, b"return 2+2")
            self.assertEqual(result, b"-> 4\n")
            conn.sendall.assert_called_once_with(b"return 2+2")
            conn.shutdown.assert_called_once_with(rpc.socket.SHUT_WR)


if __name__ == "__main__":
    unittest.main()
