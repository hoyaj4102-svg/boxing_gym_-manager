export function evaluateSchedulerMode(mode) {
  if (mode === "live") {
    return {
      ok: false,
      dryRun: false,
      providerCalls: 0,
      reason: "live_not_enabled",
    };
  }

  if (mode && mode !== "dry-run") {
    return {
      ok: false,
      dryRun: false,
      providerCalls: 0,
      reason: "unknown_mode",
    };
  }

  return {
    ok: true,
    dryRun: true,
    providerCalls: 0,
    reason: "dry_run",
  };
}

export function validateSchedulerWorkflow(workflow) {
  const errors = [];
  if (!workflow.startsWith("name: Charge Toss Subscriptions\n")) {
    errors.push("workflow name changed");
  }
  if (/^\s*schedule\s*:/m.test(workflow) || /^\s*cron\s*:/m.test(workflow)) {
    errors.push("workflow still has a schedule");
  }
  if (!workflow.includes("workflow_dispatch:")) {
    errors.push("manual dry run is missing");
  }
  if (!workflow.includes("- dry-run")) {
    errors.push("dry-run mode is missing");
  }
  if (workflow.includes("environment: production")) {
    errors.push("workflow still targets the production environment");
  }
  if (/functions\/v1\//.test(workflow) || /\bcurl\b/.test(workflow)) {
    errors.push("workflow still calls a billing endpoint");
  }
  if (!workflow.includes("node scripts/check-billing-scheduler-dry-run.mjs")) {
    errors.push("workflow does not run the dry-run check");
  }
  if (!workflow.includes("BILLING_SCHEDULER_MODE: dry-run")) {
    errors.push("workflow does not force dry-run mode");
  }
  return errors;
}
