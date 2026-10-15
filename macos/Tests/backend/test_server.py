"""Tests of the Python backend server (python/server.py).

Usage: test_server.py <PIME python dir>

Written with assistance from Claude Code (Claude Opus 5.5).
"""

import gc
import os
import sys
import unittest
import weakref

server = None


class ServerTest(unittest.TestCase):
    def setUp(self):
        from textService import TextService
        self.created = []

        def create_service(client, guid):
            service = TextService(client)
            self.created.append(weakref.ref(service))
            return service

        self.orig_create = server.textServiceMgr.createService
        server.textServiceMgr.createService = create_service
        gc.disable()

    def tearDown(self):
        gc.enable()
        server.textServiceMgr.createService = self.orig_create

    def test_closing_a_client_frees_its_text_service(self):
        srv = server.Server()
        client = server.Client(srv)
        srv.clients["id"] = client
        reply = client.handleRequest({"method": "init", "seqNum": 1, "id": "guid", "isWindows8Above": True,
                                      "isMetroApp": False, "isUiLess": False, "isConsole": False})
        self.assertTrue(reply["success"])
        del client

        srv.remove_client("id")
        # Freed right away, without waiting for the cyclic garbage collector.
        self.assertIsNone(self.created[0]())
        self.assertNotIn("id", srv.clients)

    def test_removing_an_unknown_client(self):
        server.Server().remove_client("unknown")


def main():
    global server
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.path.insert(0, os.path.abspath(sys.argv[1]))
    import server as server_module
    server = server_module
    unittest.main(argv=sys.argv[:1] + sys.argv[2:])


if __name__ == "__main__":
    main()
