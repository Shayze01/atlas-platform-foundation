"""Gunicorn settings for the Atlas Service Desk container."""
import os

bind = "0.0.0.0:8080"
workers = 2
worker_tmp_dir = "/tmp"
timeout = 30
graceful_timeout = 10
# Access logs are off: they would record client IP addresses.
accesslog = None
errorlog = "-"
loglevel = "info"
# No runtime control socket: the root filesystem is read-only and it is not needed.
control_socket_disable = True


def on_starting(server):
    from atlas_tickets import db

    db.init(os.environ.get("ATLAS_DB_PATH", "/var/lib/atlas-tickets/tickets.db"))
