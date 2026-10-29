import { readFileSync } from "node:fs";

const workflowPath = ".github/workflows/charge-subscriptions.yml";
const workflow = readFileSync(workflowPath, "utf8");

function assert(condition, message) {
  if (!condition) {
    console.error(`${workflowPath}: ${message}`);
    process.exitCode = 1;
  }
}

assert(
  workflow.includes("cron: '10 15 * * *'"),
  "billing scheduler cron must remain 00:10 KST",
);
assert(
  workflow.includes("workflow_dispatch:"),
  "manual dispatch declaration should remain visible for guarded manual runs",
);
assert(
  workflow.includes("environment: production"),
  "billing scheduler job must use the protected production environment",
);
assert(
  workflow.includes("SUPABASE_URL: ${{ secrets.SUPABASE_URL }}"),
  "SUPABASE_URL must come from GitHub secrets",
);
assert(
  workflow.includes("CRON_SECRET: ${{ secrets.CRON_SECRET }}"),
  "CRON_SECRET must come from GitHub secrets",
);
assert(
  workflow.includes("SUPABASE_PROJECT_ID: ${{ vars.SUPABASE_PROJECT_ID }}"),
  "SUPABASE_PROJECT_ID must come from GitHub environment/repository variables",
);

assert(
  !/https:\/\/[a-z0-9-]+\.supabase\.co\/functions\/v1\//i.test(workflow),
  "Edge Function calls must not contain hard-coded Supabase project URLs",
);
assert(
  workflow.includes("${SUPABASE_URL%/}/functions/v1/${function_name}"),
  "Edge Function endpoint must be derived from SUPABASE_URL",
);
assert(
  workflow.includes("SUPABASE_URL project ref does not match SUPABASE_PROJECT_ID"),
  "workflow must fail closed when SUPABASE_URL project ref mismatches",
);

const callOrder = [...workflow.matchAll(/call_edge_function "([^"]+)"/g)].map(
  (match) => match[1],
);
assert(
  JSON.stringify(callOrder) ===
    JSON.stringify([
      "charge-subscriptions",
      "reconcile-auto-renewal-payments",
      "reconcile-initial-billing-payments",
    ]),
  `billing calls must preserve charge -> renewal reconciliation -> initial reconciliation order; got ${
    JSON.stringify(callOrder)
  }`,
);

assert(
  !/echo\s+["']?\$body/.test(workflow) &&
    !/echo\s+["']?\$\{body/.test(workflow),
  "workflow must not echo Edge Function response bodies",
);
assert(
  workflow.includes("response body omitted to avoid logging billing data"),
  "workflow should explain that response bodies are intentionally omitted",
);

if (process.exitCode) {
  process.exit(process.exitCode);
}

console.log("Billing scheduler workflow static checks passed.");
