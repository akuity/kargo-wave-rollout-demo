"""A stand-in for the two AWS APIs the Lambda lane needs, so the demo runs without AWS.

- Lambda: PUT /functions/<fn>/regions/<region>/alias/live?image=<repo>:<tag>
  points the function's live alias at a new version (like update-function-code +
  publish-version + update-alias).
- CloudWatch: GET /functions/<fn>/regions/<region>/metrics returns the live version's
  error rate and p95 duration, as Errors/Invocations and Duration would.

The version's behaviour comes from its image tag: bad-* versions fail ~30% of
invocations, slow-* versions take ~2s, anything else is healthy.
GET / lists every function, region and alias history. State is in memory only.
"""
import json
import random
from urllib.parse import parse_qs, urlsplit
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {}  # (function, region) -> {"image", "version", "updatedAt", "history"}
ROUTE = re.compile(r"^/functions/([\w.-]+)/regions/([\w.-]+)(/metrics|/alias/live)?$")


def behaviour(image):
    tag = image.rsplit(":", 1)[-1]
    error_rate = 0.30 if tag.startswith("bad-") else 0.004
    p95_ms = 2000 if tag.startswith("slow-") else 120
    return round(error_rate * random.uniform(0.8, 1.2), 4), int(p95_ms * random.uniform(0.9, 1.1))


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, obj):
        body = json.dumps(obj, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            return self.reply(200, {f"{f}/{r}": s for (f, r), s in sorted(STATE.items())})
        m = ROUTE.match(path)
        if not m or m.group(3) == "/alias/live":
            return self.reply(404, {"error": "not found"})
        s = STATE.get((m.group(1), m.group(2)))
        if s is None:
            return self.reply(404, {"error": "function not deployed in this region"})
        if m.group(3) == "/metrics":
            error_rate, p95 = behaviour(s["image"])
            return self.reply(200, {"image": s["image"], "version": s["version"],
                                    "invocations": 1000, "errors": int(1000 * error_rate),
                                    "errorRate": error_rate, "p95DurationMs": p95})
        return self.reply(200, s)

    def do_PUT(self):
        url = urlsplit(self.path)
        m = ROUTE.match(url.path)
        if not m or m.group(3) != "/alias/live":
            return self.reply(404, {"error": "not found"})
        image = parse_qs(url.query).get("image", [""])[0]
        if not image:
            return self.reply(400, {"error": "missing ?image=<repo>:<tag>"})
        s = STATE.setdefault((m.group(1), m.group(2)), {"version": 0, "history": []})
        s["version"] += 1
        s["image"] = image
        s["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        s["history"].append({"version": s["version"], "image": image, "at": s["updatedAt"]})
        print(f"{m.group(1)}/{m.group(2)}: live -> v{s['version']} {image}", flush=True)
        return self.reply(200, {"function": m.group(1), "region": m.group(2),
                                "version": s["version"], "image": image})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
