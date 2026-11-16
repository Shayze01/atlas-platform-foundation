"""DELIBERATE FAULT BUILD: broken-ignore-status.

Only the `broken-ignore-status` Docker target copies this file; the default `healthy`
target never contains it. It exists so the independent tests can prove they catch a
real defect: PATCH /api/tickets/<id> answers 200 but silently drops the status change.
Priority updates still work, so the fault is confined to status. Fictional data only.
"""
from flask import jsonify, request

from atlas_tickets import create_app

WARNING = "DELIBERATE FAULT BUILD - status updates are ignored"

app = create_app()
_update_ticket = app.view_functions["update_ticket"]
_get_ticket = app.view_functions["get_ticket"]
_environment = app.view_functions["environment"]


def update_ticket_ignoring_status(ticket_id):
    data = request.get_json(silent=True)
    if isinstance(data, dict) and "status" in data:
        data.pop("status")  # the cached body is what the real view reads
        if not data:
            return _get_ticket(ticket_id)
    return _update_ticket(ticket_id)


def environment_with_warning():
    body = _environment().get_json()
    body["warning"] = WARNING
    return jsonify(body)


app.view_functions["update_ticket"] = update_ticket_ignoring_status
app.view_functions["environment"] = environment_with_warning
