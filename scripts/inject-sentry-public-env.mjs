import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export function renderSentryPublicEnv(env) {
  const source = env || {};
  const dsn = typeof source.SENTRY_DSN === "string" ? source.SENTRY_DSN : "";
  const environment = typeof source.VERCEL_ENV === "string" ? source.VERCEL_ENV : "";
  const release = typeof source.VERCEL_GIT_COMMIT_SHA === "string" ? source.VERCEL_GIT_COMMIT_SHA : "";
  return `/* Build-time public Sentry config. An empty dsn disables the SDK. Do not commit a DSN. */\nwindow.REMEMBER_SENTRY = {\n  dsn: ${JSON.stringify(dsn)},\n  environment: ${JSON.stringify(environment)},\n  release: ${JSON.stringify(release)}\n};\n`;
}

function isDirectRun() {
  return Boolean(process.argv[1]) && import.meta.url === pathToFileURL(process.argv[1]).href;
}

if (isDirectRun()) {
  writeFileSync(new URL("../js/sentry-public-env.js", import.meta.url), renderSentryPublicEnv(process.env));
}
