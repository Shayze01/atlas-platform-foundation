"""Atlas Service Desk (demo): a small support-ticket app with fictional data only."""
import os
import re

from flask import Flask, abort, jsonify, request, send_from_directory

from . import db

PRIORITIES = ("Low", "Medium", "High", "Critical")
STATUSES = ("Open", "In progress", "Resolved", "Closed")
EXPIRY_FORMAT = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
LIMITS = {"title": (3, 120), "description": (0, 2000), "requester": (2, 80)}


def _expires_at():
    value = os.environ.get("ATLAS_EXPIRES_AT", "").strip()
    return value if EXPIRY_FORMAT.match(value) else None


def _version():
    return {
        "app": "atlas-tickets",
        "variant": os.environ.get("ATLAS_VARIANT", "unknown"),
        "revision": os.environ.get("ATLAS_REVISION", "unknown"),
        "build_time": os.environ.get("ATLAS_BUILD_TIME", "unknown"),
    }


def _error(status, message, fields=None):
    body = {"error": message}
    if fields:
        body["fields"] = fields
    return jsonify(body), status


def _json_body():
    if not request.is_json:
        abort(415)
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        abort(400)
    return data


def _text(data, name, errors):
    value = data.get(name, "")
    if not isinstance(value, str):
        errors[name] = "must be text"
        return ""
    value = value.strip()
    low, high = LIMITS[name]
    if not low <= len(value) <= high:
        errors[name] = f"must be {low}-{high} characters"
    return value


def create_app(db_path=None):
    app = Flask(__name__, static_folder=None)
    app.config["DB_PATH"] = db_path or os.environ.get("ATLAS_DB_PATH", "/var/lib/atlas-tickets/tickets.db")
    app.config["MAX_CONTENT_LENGTH"] = 16 * 1024
    app.json.sort_keys = False
    static_dir = os.path.join(os.path.dirname(__file__), "static")

    def conn():
        return db.connect(app.config["DB_PATH"])

    @app.after_request
    def security_headers(response):
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; "
            "object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        )
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.errorhandler(400)
    def bad_request(_):
        return _error(400, "Request body must be a JSON object")

    @app.errorhandler(404)
    def not_found(_):
        return _error(404, "Not found")

    @app.errorhandler(405)
    def not_allowed(_):
        return _error(405, "Method not allowed")

    @app.errorhandler(413)
    def too_large(_):
        return _error(413, "Request body too large")

    @app.errorhandler(415)
    def unsupported(_):
        return _error(415, "Content-Type must be application/json")

    @app.get("/")
    def index():
        return send_from_directory(static_dir, "index.html")

    @app.get("/static/<path:name>")
    def static_files(name):
        return send_from_directory(static_dir, name)

    @app.get("/health")
    def health():
        with conn() as c:
            c.execute("SELECT 1").fetchone()
        return jsonify(status="ok")

    @app.get("/version")
    def version():
        return jsonify(_version())

    @app.get("/api/environment")
    def environment():
        return jsonify(
            name=os.environ.get("ATLAS_ENVIRONMENT", "local"),
            expires_at=_expires_at(),
            fictional_data=True,
            version=_version(),
        )

    @app.get("/api/tickets")
    def list_tickets():
        status = request.args.get("status") or None
        priority = request.args.get("priority") or None
        if status and status not in STATUSES:
            return _error(400, "Unknown status filter")
        if priority and priority not in PRIORITIES:
            return _error(400, "Unknown priority filter")
        with conn() as c:
            return jsonify(tickets=db.list_tickets(c, status, priority))

    @app.post("/api/tickets")
    def create_ticket():
        data = _json_body()
        errors = {}
        fields = {name: _text(data, name, errors) for name in LIMITS}
        priority = data.get("priority", "Medium")
        if priority not in PRIORITIES:
            errors["priority"] = "must be one of " + ", ".join(PRIORITIES)
        if errors:
            return _error(400, "Validation failed", errors)
        with conn() as c:
            ticket = db.create_ticket(c, priority=priority, **fields)
        return jsonify(ticket), 201, {"Location": f"/api/tickets/{ticket['id']}"}

    @app.get("/api/tickets/<int:ticket_id>")
    def get_ticket(ticket_id):
        with conn() as c:
            ticket = db.get_ticket(c, ticket_id)
        return jsonify(ticket) if ticket else _error(404, "Ticket not found")

    @app.patch("/api/tickets/<int:ticket_id>")
    def update_ticket(ticket_id):
        data = _json_body()
        changes, errors = {}, {}
        if "status" in data:
            if data["status"] in STATUSES:
                changes["status"] = data["status"]
            else:
                errors["status"] = "must be one of " + ", ".join(STATUSES)
        if "priority" in data:
            if data["priority"] in PRIORITIES:
                changes["priority"] = data["priority"]
            else:
                errors["priority"] = "must be one of " + ", ".join(PRIORITIES)
        if not changes and not errors:
            errors["body"] = "provide status and/or priority"
        if errors:
            return _error(400, "Validation failed", errors)
        with conn() as c:
            ticket = db.update_ticket(c, ticket_id, changes)
        return jsonify(ticket) if ticket else _error(404, "Ticket not found")

    return app
