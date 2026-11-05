import { readFileSync } from "node:fs";
import {
  evaluateSchedulerMode,
  validateSchedulerWorkflow,
} from "./billing-scheduler-dry-run.mjs";

const workflow = readFileSync(
  ".github/workflows/charge-subscriptions.yml",
  "utf8",
);
const errors = validateSchedulerWorkflow(workflow);
const result = evaluateSchedulerMode(
  process.env.BILLING_SCHEDULER_MODE || "dry-run",
);

if (errors.length > 0 || !result.ok || result.providerCalls !== 0) {
  for (const error of errors) {
    console.error(error);
  }
  if (!result.ok) {
    console.error(`scheduler mode rejected: ${result.reason}`);
  }
  process.exit(1);
}

console.log(
  JSON.stringify({
    ok: true,
    dryRun: true,
    providerCalls: 0,
  }),
);
