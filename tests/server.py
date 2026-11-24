"""Mock MyŠkoda Public API for tests/render.sh. The X-API-Key selects the scenario; timestamps are shifted
so the data always looks freshly reported. Status codes, problem types and headers follow the real API."""
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

port, fixture, requests_log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
VIN = "TMBTEST0123456789"
PROBLEMS = "https://public.api.connect.skoda-auto.cz/problems/"
base = json.load(open(fixture))
UTC = timezone.utc


def iso(dt, digits=0):
    """Like the real API, which sends 0, 1, 3 or 9 fractional digits depending on the field."""
    s = dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S")
    frac = f"{dt.microsecond:06d}000"[:digits] if digits else ""
    return s + ("." + frac if frac else "") + "Z"


def parse_ts(s):
    return datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", s.replace("Z", "+00:00")))


def walk(node, fn):
    if isinstance(node, dict):
        for k, v in node.items():
            node[k] = fn(k, v) if isinstance(v, str) else walk(v, fn) or v
    elif isinstance(node, list):
        for v in node:
            walk(v, fn)
    return node


def shifted(r):
    """The newest capture time in the fixture becomes three minutes ago; everything else moves with it."""
    stamps = []
    walk(json.loads(json.dumps(r)), lambda k, v: stamps.append(parse_ts(v)) if k.endswith("Timestamp") else v)
    delta = datetime.now(UTC) - timedelta(minutes=3) - max(stamps)
    formats = iter([0, 1, 3, 0, 1, 3, 0, 1, 3])

    def move(k, v):
        if not k.endswith(("Timestamp", "At")):
            return v
        return iso(parse_ts(v) + delta, 9 if k.endswith("At") else next(formats))

    return walk(r, move)


def build(scenario):
    r = shifted(json.loads(json.dumps(base)))
    v = r["vehicle"]
    ch = v["charging"]["status"]
    ac = v["airConditioning"]
    now = datetime.now(UTC)
    if scenario != "heating":
        ac["state"] = "OFF"
        ac.pop("estimatedReachOfTargetTemperatureAt", None)
    if scenario == "charging":
        ch.update(state="CHARGING", plugConnectionState="CONNECTED", plugLockState="LOCKED", chargePowerInKw=10.8,
                  remainingTimeToFullyChargedInMinutes=95, chargeType="AC", fullyChargedAt=iso(now + timedelta(minutes=95)))
        ch["battery"].update(stateOfChargeInPercent=61, remainingCruisingRangeInMeters=205000)
    elif scenario == "plugged":
        ch.update(state="READY_FOR_CHARGING", plugConnectionState="CONNECTED", plugLockState="UNLOCKED")
        ch["battery"].update(stateOfChargeInPercent=100, remainingCruisingRangeInMeters=340000)
    elif scenario == "lowbat":
        ch["battery"].update(stateOfChargeInPercent=12, remainingCruisingRangeInMeters=38000)
    elif scenario == "open":
        v["status"]["overall"].update(reliableLockStatus="UNLOCKED", locked="NO", doors="OPEN", windows="OPEN")
        v["status"]["detail"]["trunk"] = "OPEN"
    elif scenario == "partial":
        # The API omits the derived state while plugged in and idle, and lists what it could not get.
        ch.pop("state")
        ch.update(plugConnectionState="CONNECTED", plugLockState="UNLOCKED")
        for k in ("status", "airConditioning", "operations", "odometer"):
            v.pop(k)
        r["errors"] = [
            {"type": "VEHICLE_STATUS_UNAVAILABLE", "description": "Vehicle status could not be retrieved."},
            {"type": "AIR_CONDITIONING_UNAVAILABLE", "description": "Air conditioning could not be retrieved."},
        ]
    elif scenario == "noac":
        v["operations"] = [o for o in v["operations"] if "AirConditioning" not in o["name"]]
    return r


def problem(status, type_, title):
    return status, {"type": PROBLEMS + type_ if type_ else "about:blank", "title": title, "status": status}


# key -> (GET failure, POST failure); keys not listed here and not in SCENARIOS are rejected as invalid.
GET_FAIL = {
    "expired": (problem(401, "api-key-expired", "Unauthorized"), {}),
    "forbidden": (problem(403, "api-key-not-authorized", "Forbidden"), {}),
    "ratelimit": (problem(429, "rate-limit-exceeded", "Too Many Requests"), {"Retry-After": "1200"}),
    "server": (problem(503, None, "Service Unavailable"), {"Retry-After": "120"}),
}
SCENARIOS = {"heating", "idle", "charging", "plugged", "lowbat", "open", "partial", "noac", "expiring", "lowquota",
             "acdisabled", "acdeclined"}
POST_FAIL = {
    "acdisabled": problem(422, "operation-disabled", "Unprocessable Entity"),
    "acdeclined": problem(429, "vehicle-not-accepting-requests", "Too Many Requests"),
}


class H(BaseHTTPRequestHandler):
    def reply(self, status, body=None, extra=None, content_type="application/json"):
        scenario = self.headers.get("X-API-Key", "")
        low = scenario == "lowquota"
        self.send_response(status)
        if body is not None:
            self.send_header("Content-Type", content_type)
        self.send_header("RateLimit-Limit", "20")
        self.send_header("RateLimit-Remaining", "1" if low else "17")
        self.send_header("RateLimit-Reset", "1800" if low else "3000")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        data = json.dumps(body).encode() if body is not None else b""
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorize(self):
        """Returns (key, None) when allowed, else (key, reply arguments)."""
        key = self.headers.get("X-API-Key", "")
        m = re.fullmatch(r"/api/v1/vehicles/([^/]+)(/air-conditioning/(?:start|stop))?", self.path)
        if key not in SCENARIOS and key not in GET_FAIL:
            status, body = problem(401, None, "Unauthorized")
            return key, (status, body, None, "application/problem+json")
        if key in GET_FAIL and self.command == "GET":
            (status, body), extra = GET_FAIL[key]
            return key, (status, body, extra, "application/problem+json")
        if not m:
            status, body = problem(404, None, "Not Found")
            return key, (status, body, None, "application/problem+json")
        if m.group(1) != VIN:
            status, body = problem(403, "api-key-not-authorized", "Forbidden")
            return key, (status, body, None, "application/problem+json")
        return key, None

    def do_GET(self):
        key, denied = self.authorize()
        with open(requests_log, "a") as f:
            f.write("GET " + key + "\n")
        if denied:
            return self.reply(*denied)
        days = 5 if key == "expiring" else 120
        expires = iso(datetime.now(UTC) + timedelta(days=days, hours=3), 3)
        self.reply(200, build(key), {"X-API-Key-Expires-At": expires})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        key, denied = self.authorize()
        with open(requests_log, "a") as f:
            f.write("POST " + self.path.rsplit("/", 1)[-1] + " " + key + " " + (body or "-") + "\n")
        if denied:
            return self.reply(*denied)
        if key in POST_FAIL:
            status, problem_body = POST_FAIL[key]
            return self.reply(status, problem_body, None, "application/problem+json")
        self.reply(202)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", port), H).serve_forever()
