# Serves one page on 127.0.0.1 that puts a list of files into window.name
# (as JSON with base64 contents), so the same browser tab can carry them to
# another site.   usage: python name_bridge.py <port> <seconds> <root> <file> [<file> ...]
import sys, json, base64, os, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

port, life, root, files = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4:]
items = []
for rel in files:
    data = open(os.path.join(root, rel), "rb").read()
    items.append({"name": rel.replace("\\", "/"), "b64": base64.b64encode(data).decode("ascii")})
payload = json.dumps(items)
page = ("<!doctype html><meta charset=utf-8><title>bridge</title><body>loading<script>"
        "window.name = " + json.dumps(payload) + ";"
        "document.body.textContent = 'ready ' + JSON.parse(window.name).length + ' files';"
        "</script>").encode("utf-8")

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers(); self.wfile.write(page)
    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", port), H)
threading.Timer(life, srv.shutdown).start()
print("serving", len(items), "files,", len(page), "bytes page on", port, flush=True)
srv.serve_forever()
