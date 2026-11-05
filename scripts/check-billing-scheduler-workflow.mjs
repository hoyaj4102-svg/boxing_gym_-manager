import { readFileSync } from "node:fs";

const workflowPath = ".github/workflows/charge-subscriptions.yml";
const workflow = readFileSync(workflowPath, "utf8");
const chargeIndex = readFileSync(
  "supabase/functions/charge-subscriptions/index.ts",
  "utf8",
);

function assert(condition, message) {
  if (!condition) {
    console.error(`${workflowPath}: ${message}`);
    process.exitCode = 1;
  }
}

assert(
  workflow.startsWith("name: Charge Toss Subscriptions\n"),
  "workflow name should stay recognizable",
);
assert(
  !/^\s*schedule\s*:/m.test(workflow) && !/^\s*cron\s*:/m.test(workflow),
  "production schedule must stay disabled",
);
assert(
  workflow.includes("workflow_dispatch:"),
  "manual dry-run dispatch should stay available",
);
assert(
  workflow.includes("- dry-run") && !workflow.includes("- live"),
  "manual dispatch must offer dry-run only",
);
assert(
  !workflow.includes("environment: production"),
  "dry run must not use the production environment",
);
assert(
  !/functions\/v1\//.test(workflow) && !/\bcurl\b/.test(workflow),
  "dry run must not call a billing endpoint",
);
assert(
  workflow.includes("node scripts/check-billing-scheduler-dry-run.mjs"),
  "dry run must execute the local checker",
);
assert(
  workflow.includes("BILLING_SCHEDULER_MODE: dry-run"),
  "manual run must force dry-run mode",
);
assert(
  chargeIndex.includes("if (!isLiveBillingCharge"),
  "charge function must check the live mode before doing work",
);
assert(
  chargeIndex.indexOf("if (!isLiveBillingCharge") <
    chargeIndex.indexOf("const admin = getAdminClient()"),
  "charge function must return before opening a client when not live",
);

if (process.exitCode) {
  process.exit(process.exitCode);
}

console.log("Billing scheduler workflow static checks passed.");
