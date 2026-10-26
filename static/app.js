"use strict";
const progress = document.querySelector("[data-report]");
if (progress) {
  const timer = window.setInterval(async () => {
    try {
      const response = await fetch(progress.dataset.report, { credentials: "same-origin" });
      if (!response.ok) {
        progress.textContent = "Status refresh failed. Reload and sign in if necessary.";
        window.clearInterval(timer);
        return;
      }
      const report = await response.json();
      for (const [id, step] of Object.entries(report.steps)) {
        const status = document.querySelector(`[data-step="${CSS.escape(id)}"]`);
        const error = document.querySelector(`[data-error="${CSS.escape(id)}"]`);
        if (status) status.textContent = step.status;
        if (error) error.textContent = step.error || "";
      }
      for (const cell of document.querySelectorAll("[data-user-count]")) {
        const states = document.querySelectorAll(
          `[data-step][data-user="${CSS.escape(cell.dataset.userCount)}"]`
        );
        cell.textContent = String(
          Array.from(states).filter((state) => state.textContent === cell.dataset.status).length
        );
      }
      for (const [user, state] of Object.entries(report.background.teams)) {
        const worker = document.querySelector(`[data-teams-worker="${CSS.escape(user)}"]`);
        if (worker) worker.textContent = state;
      }
      const emailWorker = document.querySelector("[data-email-worker]");
      if (emailWorker) emailWorker.textContent = report.background.email;
      progress.textContent = "Status updated. Reload to see newly available execution controls.";
    } catch {
      progress.textContent = "Network error refreshing status. Reload to retry.";
      window.clearInterval(timer);
    }
  }, 10000);
}
