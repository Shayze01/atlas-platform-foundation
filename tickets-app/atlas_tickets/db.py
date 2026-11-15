"""SQLite storage. The database file lives only on the container's data volume."""
import contextlib
import datetime
import os
import sqlite3

SCHEMA = """
CREATE TABLE IF NOT EXISTS tickets (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    title       TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    requester   TEXT NOT NULL,
    priority    TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'Open',
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS history (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    ticket_id INTEGER NOT NULL REFERENCES tickets(id),
    at        TEXT NOT NULL,
    field     TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT NOT NULL
);
"""

SEED = [
    ("VPN drops every 20 minutes", "Remote laptop loses the VPN tunnel roughly every 20 minutes since this morning.",
     "Sam Example", "High", "Open"),
    ("New starter needs a laptop", "Alex Sample starts on Monday in Finance and needs a standard laptop build.",
     "Jordan Demo", "Medium", "In progress"),
    ("Shared printer offline on floor 2", "The floor 2 printer shows 'offline' for everyone.",
     "Riley Placeholder", "Low", "Open"),
    ("Email delivery delayed", "External emails to example.com arrive 30-40 minutes late.",
     "Casey Fictional", "Critical", "In progress"),
    ("Password reset for test account", "Test account demo.user@example.com is locked out.",
     "Sam Example", "Medium", "Resolved"),
    ("Monitor flickers", "Second monitor flickers when docked.", "Taylor Mock", "Low", "Closed"),
]


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@contextlib.contextmanager
def connect(path):
    c = sqlite3.connect(path, timeout=10)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys = ON")
    try:
        yield c
        c.commit()
    finally:
        c.close()


def init(path):
    """Creates the schema and seeds fictional tickets once. Safe to call repeatedly."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with connect(path) as c:
        c.execute("PRAGMA journal_mode = WAL")
        c.executescript(SCHEMA)
        if c.execute("SELECT COUNT(*) FROM tickets").fetchone()[0] == 0:
            for title, description, requester, priority, status in SEED:
                ticket = create_ticket(c, title, description, requester, priority)
                if status != "Open":
                    update_ticket(c, ticket["id"], {"status": status})


def _ticket(row):
    t = dict(row)
    t["reference"] = f"ATL-{1000 + t['id']}"
    return t


def list_tickets(c, status=None, priority=None):
    sql, args = "SELECT * FROM tickets WHERE 1=1", []
    if status:
        sql += " AND status = ?"
        args.append(status)
    if priority:
        sql += " AND priority = ?"
        args.append(priority)
    sql += " ORDER BY id DESC"
    return [_ticket(r) for r in c.execute(sql, args)]


def get_ticket(c, ticket_id):
    row = c.execute("SELECT * FROM tickets WHERE id = ?", (ticket_id,)).fetchone()
    if row is None:
        return None
    ticket = _ticket(row)
    ticket["history"] = [
        dict(h) for h in c.execute(
            "SELECT at, field, old_value, new_value FROM history WHERE ticket_id = ? ORDER BY id", (ticket_id,))
    ]
    return ticket


def create_ticket(c, title, description, requester, priority):
    ts = now()
    cur = c.execute(
        "INSERT INTO tickets (title, description, requester, priority, status, created_at, updated_at)"
        " VALUES (?, ?, ?, ?, 'Open', ?, ?)",
        (title, description, requester, priority, ts, ts),
    )
    c.execute("INSERT INTO history (ticket_id, at, field, old_value, new_value) VALUES (?, ?, 'created', NULL, 'Open')",
              (cur.lastrowid, ts))
    return get_ticket(c, cur.lastrowid)


def update_ticket(c, ticket_id, changes):
    current = get_ticket(c, ticket_id)
    if current is None:
        return None
    ts = now()
    for field in ("status", "priority"):
        if field in changes and changes[field] != current[field]:
            c.execute(f"UPDATE tickets SET {field} = ?, updated_at = ? WHERE id = ?", (changes[field], ts, ticket_id))
            c.execute("INSERT INTO history (ticket_id, at, field, old_value, new_value) VALUES (?, ?, ?, ?, ?)",
                      (ticket_id, ts, field, current[field], changes[field]))
    return get_ticket(c, ticket_id)
