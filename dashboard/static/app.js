"use strict";

const REFRESH_INTERVAL_MS = 10_000;
let refreshInFlight = false;

const projectList = document.querySelector("#project-list");
const refreshButton = document.querySelector("#refresh-button");
const refreshError = document.querySelector("#refresh-error");
const registryErrors = document.querySelector("#registry-errors");
const lastRefresh = document.querySelector("#last-refresh");

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function stateLabel(state) {
  const labels = {
    automated_work_complete: "COMPLETE",
    pending_human: "HUMAN REVIEW",
    not_initialized: "NOT INITIALIZED",
    state_unavailable: "STATE UNAVAILABLE",
    configuration_error: "CONFIGURATION ERROR",
  };
  return labels[state] || String(state || "STATE UNAVAILABLE").replaceAll("_", " ").toUpperCase();
}

function nextLabel(next) {
  if (!next) return "Unavailable";
  if (next.startsWith("NEXT_TASK=")) return `Next task: ${next.slice("NEXT_TASK=".length)}`;
  const labels = {
    MILESTONE_COMPLETE: "Milestone work complete",
    MILESTONE_BLOCKED: "Resolve blocked milestone state",
    NO_READY_TASK: "No task is currently ready",
  };
  return labels[next] || next.replaceAll("_", " ");
}

function renderSummary(summary) {
  for (const key of ["projects", "active", "attention", "complete"]) {
    document.querySelector(`#summary-${key}`).textContent = String(summary[key] ?? 0);
  }
}

function addField(parent, label, value, extraClass = "") {
  const field = element("div", `field ${extraClass}`.trim());
  field.append(element("span", "field-label", label), element("strong", "field-value", value));
  parent.append(field);
}

function renderProject(project) {
  const card = element("article", `project-card state-${project.classification}`);
  const header = element("header", "project-header");
  const identity = element("div", "project-identity");
  identity.append(element("p", "project-code", project.id), element("h3", "", project.name));

  const badge = element("span", `status-badge ${project.classification}`, stateLabel(project.state));
  header.append(identity, badge);

  const platforms = element("div", "platforms");
  platforms.setAttribute("aria-label", "Platforms");
  for (const platform of project.platforms) platforms.append(element("span", "platform", platform.toUpperCase()));

  const body = element("div", "project-body");
  const progress = element("div", "progress-block");
  const progressTop = element("div", "progress-top");
  progressTop.append(element("span", "field-label", "Progress"));

  const percent = project.milestone?.percent;
  progressTop.append(element("strong", "progress-percent", percent === null || percent === undefined ? "UNAVAILABLE" : `${percent}%`));
  const track = element("div", "progress-track");
  track.setAttribute("role", "progressbar");
  if (percent === null || percent === undefined) {
    track.classList.add("unavailable");
    track.setAttribute("aria-label", "Progress unavailable");
  } else {
    track.setAttribute("aria-valuemin", "0");
    track.setAttribute("aria-valuemax", "100");
    track.setAttribute("aria-valuenow", String(percent));
  }
  const fill = element("span", "progress-fill");
  fill.style.width = `${percent ?? 0}%`;
  track.append(fill);
  const count = project.milestone ? `${project.milestone.passed} / ${project.milestone.total} tasks` : "Task progress unavailable";
  progress.append(progressTop, track, element("p", "task-count", count));

  const details = element("div", "details-grid");
  addField(details, "Active milestone", project.active_milestone || "Not configured");
  addField(details, "Milestone title", project.milestone?.title || "Unavailable");
  addField(details, "Next Game Foundry action", nextLabel(project.milestone?.next), "wide");
  body.append(progress, details);

  card.append(header, platforms, body);
  if (project.error) card.append(element("p", "project-error", project.error));
  return card;
}

function renderProjects(projects) {
  projectList.replaceChildren();
  if (!projects.length) {
    projectList.append(element("div", "empty-panel", "No valid projects are registered."));
    return;
  }
  for (const project of projects) projectList.append(renderProject(project));
}

function showRegistryErrors(errors) {
  registryErrors.replaceChildren();
  registryErrors.hidden = !errors.length;
  if (!errors.length) return;
  registryErrors.append(element("strong", "", "Registry warning"));
  const list = element("ul");
  for (const message of errors) list.append(element("li", "", message));
  registryErrors.append(list);
}

async function refreshProjects() {
  if (refreshInFlight) return;
  refreshInFlight = true;
  refreshButton.disabled = true;
  refreshButton.textContent = "Refreshing…";
  try {
    const response = await fetch("/api/projects", { cache: "no-store" });
    if (!response.ok) throw new Error(`Dashboard API returned ${response.status}`);
    const payload = await response.json();
    renderSummary(payload.summary);
    renderProjects(payload.projects);
    showRegistryErrors(payload.registry_errors || []);
    const refreshedAt = new Date(payload.generated_at);
    lastRefresh.textContent = `Last refresh ${refreshedAt.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}`;
    refreshError.hidden = true;
  } catch (error) {
    refreshError.textContent = `Refresh failed. Last successful project data remains visible. ${error.message}`;
    refreshError.hidden = false;
  } finally {
    refreshInFlight = false;
    refreshButton.disabled = false;
    refreshButton.textContent = "Refresh";
  }
}

refreshButton.addEventListener("click", refreshProjects);
refreshProjects();
setInterval(refreshProjects, REFRESH_INTERVAL_MS);
