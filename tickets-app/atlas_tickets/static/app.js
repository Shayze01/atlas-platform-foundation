"use strict";
// Atlas Service Desk (demo) front end. Uses textContent only (no innerHTML with data).
const $ = (sel, root = document) => root.querySelector(sel);
const view = () => $("#view");

async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", Accept: "application/json" },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const fields = body.fields ? Object.entries(body.fields).map(([k, v]) => `${k} ${v}`).join("; ") : "";
    throw new Error(fields || body.error || `HTTP ${res.status}`);
  }
  return body;
}

function el(tag, text, cls) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (cls) node.className = cls;
  return node;
}

const slug = (v) => v.toLowerCase().replace(/\s+/g, "-");
const fmt = (iso) => (iso ? iso.replace("T", " ").replace("Z", "") : "");

function badge(node, kind, value) {
  node.textContent = value;
  node.className = `badge ${kind}-${slug(value)}`;
}

function mount(id) {
  const fragment = $(id).content.cloneNode(true);
  view().replaceChildren(fragment);
}

async function loadEnvironment() {
  const banner = $("#env-banner");
  try {
    const env = await api("/api/environment");
    const v = env.version;
    $("#version").textContent = `Image ${v.variant} @ ${v.revision.slice(0, 12)}`;
    banner.replaceChildren();
    if (env.warning) banner.append(el("strong", `${env.warning} · `, "warning"));
    const label = env.name === "preview" ? "Browser preview (not Azure)" : `Environment: ${env.name}`;
    banner.append(el("strong", label));
    if (env.expires_at) {
      const local = new Date(env.expires_at).toLocaleString();
      banner.append(el("span", ` · Planned expiry ${fmt(env.expires_at)} UTC (${local} your time).`));
      banner.append(el("span", " After cleanup this address stops working and all tickets are deleted.", "muted-light"));
      if (env.name === "preview") {
        banner.append(el("span", " (Sample time only: the preview has no expiry timer or cleanup.)", "muted-light"));
      }
      banner.dataset.expiresAt = env.expires_at;
    } else {
      banner.append(el("span", " · No expiry set for this environment."));
    }
    if (v.variant !== "healthy" || env.warning) banner.classList.add("danger");
  } catch (e) {
    banner.textContent = `Environment details unavailable: ${e.message}`;
  }
}

async function renderList() {
  mount("#tpl-list");
  const params = new URLSearchParams(location.hash.split("?")[1] || "");
  const status = $("#filter-status"), priority = $("#filter-priority");
  status.value = params.get("status") || "";
  priority.value = params.get("priority") || "";
  const onFilter = () => {
    const q = new URLSearchParams();
    if (status.value) q.set("status", status.value);
    if (priority.value) q.set("priority", priority.value);
    location.hash = `#/${q.toString() ? "?" + q : ""}`;
  };
  status.addEventListener("change", onFilter);
  priority.addEventListener("change", onFilter);

  const { tickets } = await api(`/api/tickets?${params}`);
  const rows = $("#ticket-rows");
  for (const t of tickets) {
    const tr = el("tr");
    tr.dataset.testid = "ticket-row";
    const ref = el("td");
    const link = el("a", t.reference);
    link.href = `#/tickets/${t.id}`;
    ref.append(link);
    const title = el("td");
    const tlink = el("a", t.title);
    tlink.href = `#/tickets/${t.id}`;
    title.append(tlink);
    const pr = el("td"), st = el("td");
    pr.append(el("span")); badge(pr.firstChild, "priority", t.priority);
    st.append(el("span")); badge(st.firstChild, "status", t.status);
    tr.append(ref, title, el("td", t.requester), pr, st, el("td", fmt(t.updated_at)));
    rows.append(tr);
  }
  $("#empty").classList.toggle("hidden", tickets.length > 0);
  const open = tickets.filter((t) => t.status === "Open" || t.status === "In progress").length;
  $("#stats").textContent = `${tickets.length} shown · ${open} open or in progress`;
}

function renderNew() {
  mount("#tpl-new");
  const form = $("#new-form");
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = Object.fromEntries(new FormData(form).entries());
    const err = $("#form-error");
    try {
      const ticket = await api("/api/tickets", { method: "POST", body: JSON.stringify(data) });
      location.hash = `#/tickets/${ticket.id}`;
    } catch (e) {
      err.textContent = `Could not create ticket: ${e.message}`;
      err.classList.remove("hidden");
    }
  });
}

async function renderDetail(id) {
  mount("#tpl-detail");
  const fill = (t) => {
    $("#d-ref").textContent = t.reference;
    $("#d-title").textContent = t.title;
    badge($("#d-priority"), "priority", t.priority);
    badge($("#d-status"), "status", t.status);
    $("#d-requester").textContent = t.requester;
    $("#d-created").textContent = fmt(t.created_at);
    $("#d-updated").textContent = fmt(t.updated_at);
    $("#d-description").textContent = t.description || "No description.";
    $("#u-status").value = t.status;
    $("#u-priority").value = t.priority;
    const list = $("#d-history");
    list.replaceChildren();
    for (const h of t.history) {
      const text = h.field === "created" ? "Ticket created (Open)" : `${h.field}: ${h.old_value} → ${h.new_value}`;
      const li = el("li");
      li.append(el("time", fmt(h.at)), el("span", text));
      list.append(li);
    }
    document.title = `${t.reference} · Atlas Service Desk (demo)`;
  };
  try {
    fill(await api(`/api/tickets/${id}`));
  } catch (e) {
    const back = el("a", "Back to all tickets");
    back.href = "#/";
    view().replaceChildren(el("p", `Ticket ${id}: ${e.message}.`, "error"), back);
    return;
  }
  $("#update-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const msg = $("#u-msg");
    msg.textContent = "Saving...";
    try {
      const body = JSON.stringify({ status: $("#u-status").value, priority: $("#u-priority").value });
      fill(await api(`/api/tickets/${id}`, { method: "PATCH", body }));
      msg.textContent = "Saved.";
    } catch (e) {
      msg.textContent = `Save failed: ${e.message}`;
    }
  });
}

async function route() {
  const hash = location.hash || "#/";
  const detail = hash.match(/^#\/tickets\/(\d+)$/);
  document.title = "Atlas Service Desk (demo)";
  try {
    if (detail) await renderDetail(detail[1]);
    else if (hash.startsWith("#/new")) renderNew();
    else await renderList();
  } catch (e) {
    view().replaceChildren(el("p", `Something went wrong: ${e.message}`, "error"));
  }
}

window.addEventListener("hashchange", route);
document.addEventListener("DOMContentLoaded", () => {
  loadEnvironment();
  route();
});
