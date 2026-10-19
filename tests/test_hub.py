"""roster-hub against a fake roster CLI, on 127.0.0.1, with throwaway state.

    python3 -m unittest discover -s tests -v
"""

import http.client
import http.server
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HUB = os.path.join(os.path.dirname(HERE), "bin", "roster-hub")
FAKE = os.path.join(HERE, "fake_roster")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def ago(secs):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(time.time() - secs))


def row(name, status, machine="hub1", local=True, since=5, **extra):
    r = {"name": name, "status": status, "status_at": ago(since), "role": "role of %s" % name,
         "machine": machine, "local": local, "unread": 0, "backend": "tmux", "cwd": "/tmp"}
    r.update(extra)
    return r


class PushSink(http.server.BaseHTTPRequestHandler):
    """Stands in for ntfy: keeps every POST."""
    got = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        PushSink.got.append({"path": self.path, "auth": self.headers.get("Authorization"),
                             "body": json.loads(body)})
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


class HubTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="roster-hub-test.")
        cls.fake_dir = os.path.join(cls.tmp, "fake")
        os.makedirs(cls.fake_dir)
        cls.set_rows([row("infra", "idle"), row("worker", "working", since=120),
                      row("asker", "working"), row("web", "idle", machine="laptop", local=False)])
        cls.sink = http.server.ThreadingHTTPServer(("127.0.0.1", 0), PushSink)
        threading.Thread(target=cls.sink.serve_forever, daemon=True).start()
        cls.sink_url = "http://127.0.0.1:%d/" % cls.sink.server_address[1]
        token_file = os.path.join(cls.tmp, "ntfy-token")
        with open(token_file, "w") as f:
            f.write("ntfy-secret\n")
        cls.port = free_port()
        os.makedirs(os.path.join(cls.tmp, "config", "roster"))
        cls.web = os.path.join(cls.tmp, "web")
        os.makedirs(os.path.join(cls.web, "assets"))
        for rel, text in (("index.html", "<!doctype html>app"), ("main.dart.js", "main()"),
                          ("canvaskit.wasm", "\0asm"), ("assets/a.json", "{}")):
            with open(os.path.join(cls.web, rel), "w") as f:
                f.write(text)
        with open(os.path.join(cls.tmp, "secret.txt"), "w") as f:
            f.write("outside the web folder")
        with open(os.path.join(cls.tmp, "config", "roster", "hub.toml"), "w") as f:
            f.write('listen = "127.0.0.1:%d"\npublic_url = "https://hub.example"\n'
                    'push_token_file = "%s"\npush_allowed = ["%s"]\nweb_dir = "%s"\n'
                    % (cls.port, token_file, cls.sink_url, cls.web))
        cls.env = dict(os.environ, XDG_STATE_HOME=os.path.join(cls.tmp, "state"),
                       XDG_CONFIG_HOME=os.path.join(cls.tmp, "config"), ROSTER_BIN=FAKE,
                       FAKE_ROSTER_DIR=cls.fake_dir)
        cls.log = open(os.path.join(cls.tmp, "hub.log"), "w")
        cls.proc = subprocess.Popen([sys.executable, HUB, "serve"], env=cls.env, stdout=cls.log, stderr=cls.log)
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.05)
        cls.token, cls.device_id = cls.pair("main-phone")

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(10)
        cls.sink.shutdown()
        cls.log.close()
        if os.environ.get("KEEP"):
            print("kept", cls.tmp)
        else:
            shutil.rmtree(cls.tmp)

    @classmethod
    def set_rows(cls, rows):
        path = os.path.join(cls.fake_dir, "rows.json")
        with open(path + ".new", "w") as f:
            json.dump(rows, f)
        os.replace(path + ".new", path)

    @classmethod
    def hub_cli(cls, *args):
        return subprocess.run([sys.executable, HUB, *args], env=cls.env, capture_output=True, text=True, timeout=20)

    @classmethod
    def request(cls, method, path, body=None, token=None, headers=None, raw=None):
        conn = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=20)
        h = dict(headers or {})
        if token:
            h["Authorization"] = "Bearer " + token
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        if data is not None:
            h["Content-Type"] = "application/json"
        conn.request(method, path, body=data, headers=h)
        resp = conn.getresponse()
        text = resp.read()
        conn.close()
        return resp.status, json.loads(text) if text else None

    @classmethod
    def pair(cls, name=None, xff="198.51.100.1"):
        out = cls.hub_cli("pair", "--json", *(["--name", name] if name else []))
        assert out.returncode == 0, out.stderr
        code = json.loads(out.stdout)["code"]
        status, got = cls.request("POST", "/v1/pair", {"code": code, "device_name": "app"},
                                  headers={"X-Forwarded-For": xff})
        assert status == 200, got
        return got["token"], got["device_id"]

    def calls(self):
        with open(os.path.join(self.fake_dir, "calls.jsonl")) as f:
            return [json.loads(l) for l in f]

    def wait_for(self, fn, timeout=8):
        end = time.time() + timeout
        while time.time() < end:
            got = fn()
            if got:
                return got
            time.sleep(0.05)
        self.fail("timed out")

    # --- tests ---

    def test_version_needs_no_token(self):
        self.assertEqual(self.request("GET", "/v1/version"), (200, {"hub": "0.3.0", "api": 1}))

    def test_unknown_path_is_404_json(self):
        status, got = self.request("GET", "/v1/nothing", token=self.token)
        self.assertEqual(status, 404)
        self.assertIn("error", got)

    def test_auth_rejected(self):
        self.assertEqual(self.request("GET", "/v1/agents")[0], 401)
        self.assertEqual(self.request("GET", "/v1/agents", token="not-a-token")[0], 401)
        self.assertEqual(self.request("GET", "/v1/agents", headers={"Authorization": "Basic " + self.token})[0], 401)
        self.assertEqual(self.request("GET", "/v1/events", token=self.token + "x")[0], 401)

    def test_state_holds_only_hashes(self):
        path = os.path.join(self.tmp, "state", "roster", "hub", "devices.json")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        with open(path) as f:
            text = f.read()
        self.assertNotIn(self.token, text)
        dev = next(d for d in json.loads(text)["devices"] if d["id"] == self.device_id)
        self.assertEqual(dev["name"], "main-phone")  # --name wins over the app's device_name

    def test_pair_code_is_single_use(self):
        code = json.loads(self.hub_cli("pair", "--json").stdout)["code"]
        h = {"X-Forwarded-For": "198.51.100.2"}
        status, got = self.request("POST", "/v1/pair", {"code": code.lower(), "device_name": "x"}, headers=h)
        self.assertEqual(status, 200)
        self.assertEqual(len(got["token"]), 43)  # 32 bytes, urlsafe base64 without padding
        self.assertEqual(self.request("POST", "/v1/pair", {"code": code, "device_name": "x"}, headers=h)[0], 403)

    def test_pair_rate_limit(self):
        h = {"X-Forwarded-For": "10.9.9.9, 203.0.113.9"}
        for _ in range(5):
            self.assertEqual(self.request("POST", "/v1/pair", {"code": "AAAAAAAA"}, headers=h)[0], 403)
        code = json.loads(self.hub_cli("pair", "--json").stdout)["code"]
        status, got = self.request("POST", "/v1/pair", {"code": code}, headers=h)
        self.assertEqual(status, 429)  # even the right code, once over the limit
        # another address is not affected, and the code was not used up
        self.assertEqual(self.request("POST", "/v1/pair", {"code": code}, headers={"X-Forwarded-For": "203.0.113.10"})[0], 200)

    def test_body_limit(self):
        status, _ = self.request("POST", "/v1/prompt", token=self.token, raw=b"x" * (256 * 1024 + 1))
        self.assertEqual(status, 413)
        self.assertEqual(self.request("POST", "/v1/prompt", token=self.token, raw=b"[1]")[0], 400)

    def test_agents(self):
        status, got = self.request("GET", "/v1/agents", token=self.token)
        self.assertEqual(status, 200)
        agents = {r["agent"] for r in got["agents"]}
        self.assertIn("infra@hub1", agents)
        self.assertIn("web@laptop", agents)
        machines = {m["name"]: m for m in got["machines"]}
        self.assertEqual(got["machines"][0]["name"], "hub1")
        self.assertTrue(machines["hub1"]["local"])
        self.assertTrue(machines["laptop"]["reachable"])
        # no agents there, so known only from `roster peer list`; it appears once that ran
        self.wait_for(lambda: any(m["name"] == "idle-box" for m in self.request("GET", "/v1/agents", token=self.token)[1]["machines"]))
        idle = next(m for m in self.request("GET", "/v1/agents", token=self.token)[1]["machines"] if m["name"] == "idle-box")
        self.assertFalse(idle["reachable"])
        self.assertIn("connection refused", idle["error"])
        self.request("GET", "/v1/agents?all=1", token=self.token)
        self.assertIn(["list", "--json", "--all"], [c["argv"] for c in self.calls()])

    def test_events_first_event(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("GET", "/v1/events", headers={"Authorization": "Bearer " + self.token})
        resp = conn.getresponse()
        self.assertEqual(resp.status, 200)
        self.assertTrue(resp.getheader("Content-Type").startswith("text/event-stream"))
        lines = []
        while True:
            line = resp.fp.readline().decode().rstrip("\n")
            if not line:
                break
            lines.append(line)
        conn.close()
        self.assertEqual(lines[0], "event: agents")
        self.assertTrue(lines[1].startswith("id: "))
        data = json.loads("".join(l[len("data: "):] for l in lines[2:]))
        self.assertIn("agents", data)
        self.assertIn("machines", data)

    def test_prompt(self):
        status, got = self.request("POST", "/v1/prompt", {"agent": "infra@hub1", "text": "hello\nthere"}, token=self.token)
        self.assertEqual((status, got), (200, {"ok": True}))
        self.assertIn({"argv": ["prompt", "infra@hub1", "-"], "stdin": "hello\nthere"}, self.calls())
        for bad in ("infra", "-rf@hub1", "Infra@hub1", "infra@hub1\n", "a/../b@hub1", "infra@-x", "x@y@z z"):
            status, got = self.request("POST", "/v1/prompt", {"agent": bad, "text": "x"}, token=self.token)
            self.assertEqual(status, 400, bad)
        self.assertEqual(self.request("POST", "/v1/prompt", {"agent": "infra@hub1", "text": ""}, token=self.token)[0], 400)
        # the CLI's refusal comes through with its reason
        status, got = self.request("POST", "/v1/prompt", {"agent": "busy@hub1", "text": "x"}, token=self.token)
        self.assertEqual(status, 400)
        self.assertEqual(got["error"], "busy@hub1 has a dialog open; answer it with keys")

    def test_keys(self):
        status, _ = self.request("POST", "/v1/keys", {"agent": "infra@hub1", "keys": ["2", "Enter"]}, token=self.token)
        self.assertEqual(status, 200)
        self.assertIn(["keys", "infra@hub1", "2", "Enter"], [c["argv"] for c in self.calls()])
        for bad in (["C-c"], ["x"], ["Enter", "-t"], [], "Enter", [1], ["Up"] * 33):
            self.assertEqual(self.request("POST", "/v1/keys", {"agent": "infra@hub1", "keys": bad}, token=self.token)[0], 400, bad)

    def test_new_resume_kill(self):
        status, got = self.request("POST", "/v1/new", {"machine": "hub1", "cwd": "-x", "name": "docs", "role": "writes docs",
                                                        "prompt": "go"}, token=self.token)
        self.assertEqual((status, got), (200, {"agent": "docs@hub1"}))
        self.assertIn({"argv": ["new", "--on=hub1", "--no-attach", "--name=docs", "--role=writes docs", "--prompt=-",
                                "--json", "--", "-x"], "stdin": "go"}, self.calls())
        self.assertEqual(self.request("POST", "/v1/new", {"machine": "hub1", "model": "opus", "effort": "xhigh"},
                                      token=self.token)[0], 200)
        self.assertIn(["new", "--on=hub1", "--no-attach", "--model=opus", "--effort=xhigh", "--json"],
                      [c["argv"] for c in self.calls()])
        self.assertEqual(self.request("POST", "/v1/new", {"machine": "hub1", "effort": "huge"}, token=self.token)[0], 400)
        self.assertEqual(self.request("POST", "/v1/new", {"machine": "hub1", "model": "opus; rm"}, token=self.token)[0], 400)
        self.assertEqual(self.request("POST", "/v1/new", {"machine": "laptop"}, token=self.token), (200, {"agent": "ab12cd34@laptop"}))
        self.assertEqual(self.request("POST", "/v1/new", {"machine": "-x"}, token=self.token)[0], 400)
        self.assertEqual(self.request("POST", "/v1/new", {"machine": "hub1", "name": "Bad Name"}, token=self.token)[0], 400)
        self.assertEqual(self.request("POST", "/v1/new", {"machine": "hub1", "role": "two\nlines"}, token=self.token)[0], 400)
        self.assertEqual(self.request("POST", "/v1/resume", {"agent": "infra@hub1"}, token=self.token), (200, {"ok": True}))
        self.assertIn(["resume", "infra@hub1", "--no-attach"], [c["argv"] for c in self.calls()])
        status, got = self.request("POST", "/v1/kill", {"agent": "nobody@hub1"}, token=self.token)
        self.assertEqual((status, got), (400, {"error": "no agent named nobody on the roster"}))

    def test_transcript_and_screen(self):
        status, got = self.request("GET", "/v1/transcript?agent=infra@hub1&after=4&limit=50", token=self.token)
        self.assertEqual(status, 200)
        self.assertEqual(got["next"], 3)
        self.assertIn(["transcript", "infra@hub1", "--after", "4", "--limit", "50", "--json"], [c["argv"] for c in self.calls()])
        self.assertEqual(self.request("GET", "/v1/transcript?agent=infra@hub1&limit=0", token=self.token)[0], 400)
        self.assertEqual(self.request("GET", "/v1/transcript?agent=infra@hub1&after=x", token=self.token)[0], 400)
        status, got = self.request("GET", "/v1/screen?agent=infra@hub1", token=self.token)
        self.assertEqual(got["dialog"]["options"][0]["key"], "1")
        self.assertEqual(self.request("GET", "/v1/screen", token=self.token)[0], 400)

    def test_push_endpoint_must_be_allowed(self):
        token, _ = self.pair(xff="198.51.100.3")
        self.assertEqual(self.request("POST", "/v1/push", {"endpoint": "https://evil.example/up"}, token=token)[0], 400)
        self.assertEqual(self.request("POST", "/v1/push", {"endpoint": self.sink_url + "up1"}, token=token), (200, {"ok": True}))
        devs = self.request("GET", "/v1/devices", token=token)[1]["devices"]
        me = next(d for d in devs if d["current"])
        self.assertTrue(me["push"])
        self.assertEqual(self.request("POST", "/v1/push", {"endpoint": None}, token=token), (200, {"ok": True}))

    def test_push_on_change(self):
        """An agent that finishes after working 2 minutes, and one that blocks, each send a push; the stream sees it too."""
        self.assertEqual(self.request("POST", "/v1/push", {"endpoint": self.sink_url + "upmain"}, token=self.token)[0], 200)
        self.request("GET", "/v1/agents", token=self.token)  # the snapshot to compare against exists
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("GET", "/v1/events", headers={"Authorization": "Bearer " + self.token})
        resp = conn.getresponse()
        first = resp.fp.readline()
        while resp.fp.readline().strip():
            pass
        self.assertEqual(first, b"event: agents\n")
        self.set_rows([row("infra", "idle"), row("worker", "idle", since=0), row("asker", "blocked", since=0),
                       row("web", "idle", machine="laptop", local=False)])
        def next_event():
            lines = []
            while True:
                line = resp.fp.readline().decode().rstrip("\n")
                if not line and lines:
                    return lines
                lines.append(line)

        for _ in range(5):  # an earlier change may still be on its way
            lines = next_event()
            self.assertEqual(lines[0], "event: agents")
            data = json.loads(lines[2][len("data: "):])
            if next(r for r in data["agents"] if r["name"] == "asker")["status"] == "blocked":
                break
        else:
            self.fail("the change never came through the stream")
        conn.close()
        got = self.wait_for(lambda: len([p for p in PushSink.got if p["path"] == "/upmain"]) >= 2 and PushSink.got)
        mine = [p for p in got if p["path"] == "/upmain"]
        self.assertTrue(all(p["auth"] == "Bearer ntfy-secret" for p in mine))
        by_type = {p["body"]["type"]: p["body"] for p in mine}
        self.assertEqual(by_type["finished"]["agent"], "worker@hub1")
        self.assertEqual(by_type["finished"]["body"], "All done: tests pass.")
        self.assertEqual(by_type["blocked"]["agent"], "asker@hub1")
        self.assertEqual(by_type["blocked"]["body"], "Do you want to run git push?")

    def test_revoke(self):
        token, dev = self.pair(xff="198.51.100.4")
        self.assertEqual(self.request("GET", "/v1/devices", token=token)[0], 200)
        out = self.hub_cli("revoke", dev)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.request("GET", "/v1/devices", token=token)[0], 401)
        self.assertEqual(self.hub_cli("revoke", dev).returncode, 1)
        # and over the API
        token2, dev2 = self.pair(xff="198.51.100.4")
        self.assertEqual(self.request("DELETE", "/v1/devices/" + dev2, token=self.token), (200, {"ok": True}))
        self.assertEqual(self.request("GET", "/v1/agents", token=token2)[0], 401)
        self.assertEqual(self.request("DELETE", "/v1/devices/" + dev2, token=self.token)[0], 404)
        self.assertNotIn(dev2, self.hub_cli("devices").stdout)

    # The web app's files at /: public, confined to web_dir, app routes get index.html.

    def web_get(self, path):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp.status, resp.getheader("Content-Type"), body

    def test_web(self):
        self.assertEqual(self.web_get("/")[0::2], (200, b"<!doctype html>app"))
        self.assertEqual(self.web_get("/agents/infra@hub1")[2], b"<!doctype html>app")  # an app route
        status, ctype, _ = self.web_get("/canvaskit.wasm")
        self.assertEqual((status, ctype), (200, "application/wasm"))
        self.assertTrue(self.web_get("/main.dart.js")[1].startswith("text/javascript"))
        self.assertEqual(self.web_get("/assets/a.json")[0], 200)
        self.assertEqual(self.web_get("/missing.js")[0], 404)
        for bad in ("/../secret.txt", "/%2e%2e/secret.txt", "/assets/../../secret.txt", "/..%2fsecret.txt"):
            status, _, body = self.web_get(bad)
            self.assertNotIn(b"outside the web folder", body, bad)
        # /v1 is still the API, with its own auth
        self.assertEqual(self.request("GET", "/v1/agents")[0], 401)


class ListenTest(unittest.TestCase):
    def test_refuses_public_and_wildcard(self):
        tmp = tempfile.mkdtemp(prefix="roster-hub-test.")
        try:
            os.makedirs(os.path.join(tmp, "roster"))
            for listen in ("0.0.0.0:8790", "[::]:8790", "8.8.8.8:8790", "example.com:80"):
                with open(os.path.join(tmp, "roster", "hub.toml"), "w") as f:
                    f.write('listen = "%s"\n' % listen)
                out = subprocess.run([sys.executable, HUB, "serve"], capture_output=True, text=True, timeout=10,
                                     env=dict(os.environ, XDG_CONFIG_HOME=tmp, XDG_STATE_HOME=tmp, ROSTER_BIN=FAKE))
                self.assertEqual(out.returncode, 1, listen)
                self.assertIn("roster-hub: listen", out.stderr)
        finally:
            shutil.rmtree(tmp)





if __name__ == "__main__":
    unittest.main()
