"""Localhost-only server for the kc-factory dashboard.

Usage: python3 -I dashboard-server.py <port> <factory-home> <index.html>

Serves the plugin's own page at / and a fixed allowlist of job files under
<factory-home>/jobs. Everything else (runs/, config, other files) is a 404.
Requests whose Host header is not 127.0.0.1:<port> or localhost:<port> get a
403, which blocks DNS-rebinding pages.
"""
import http.server
import os
import re
import sys

KEY = re.compile(r"^[A-Z][A-Z0-9]+-[0-9]+$")
FIXED = {"intake.md", "routing.json", "tracker.log", "blocked.md", "ticket.md"}
FEEDBACK = re.compile(r"^feedback-[1-9][0-9]*\.md$")


def make_handler(port, jobs_root, page_path):
    allowed_hosts = {"127.0.0.1:%d" % port, "localhost:%d" % port}

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "kc-factory-dashboard"

        def send_file(self, path, ctype, head_only):
            try:
                real = os.path.realpath(path)
                inside = real == page_path or real.startswith(jobs_root + os.sep)
                if not inside or not os.path.isfile(real):
                    return self.fail(404)
                with open(real, "rb") as f:
                    body = f.read()
            except OSError:
                return self.fail(404)
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            if not head_only:
                self.wfile.write(body)

        def fail(self, code):
            body = b"%d\n" % code
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def route(self, head_only):
            if self.headers.get("Host", "") not in allowed_hosts:
                return self.fail(403)
            path = self.path.split("?", 1)[0].split("#", 1)[0]
            if path in ("/", "/index.html"):
                return self.send_file(page_path, "text/html; charset=utf-8", head_only)
            if path == "/jobs/index.json":
                return self.send_file(
                    os.path.join(jobs_root, "index.json"),
                    "application/json; charset=utf-8", head_only)
            parts = path.split("/")
            if len(parts) == 4 and parts[0] == "" and parts[1] == "jobs" \
                    and KEY.match(parts[2]) and (parts[3] in FIXED or FEEDBACK.match(parts[3])):
                ctype = "application/json; charset=utf-8" if parts[3].endswith(".json") \
                    else "text/plain; charset=utf-8"
                return self.send_file(os.path.join(jobs_root, parts[2], parts[3]), ctype, head_only)
            return self.fail(404)

        def do_GET(self):
            self.route(False)

        def do_HEAD(self):
            self.route(True)

        def do_other(self):
            self.send_response(405)
            self.send_header("Allow", "GET, HEAD")
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_other

        def log_message(self, fmt, *args):
            pass

    return Handler


def main():
    port = int(sys.argv[1])
    jobs_root = os.path.realpath(os.path.join(sys.argv[2], "jobs"))
    page_path = os.path.realpath(sys.argv[3])
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), make_handler(port, jobs_root, page_path))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
