export function interpretConsentGate(result: {
  data: unknown;
  error: { message?: string; code?: string } | null;
}): "allow" | "deny" | "skip_missing" {
  if (result.error) {
    const message = result.error.message || "";
    const code = result.error.code || "";
    if (
      code === "42883" ||
      code === "PGRST202" ||
      /does not exist|schema cache|Could not find the function/i.test(message)
    ) {
      return "skip_missing";
    }
    return "deny";
  }

  if (!result.data || typeof result.data !== "object" || Array.isArray(result.data)) {
    return "skip_missing";
  }

  const allowed = (result.data as { allowed?: unknown }).allowed;
  if (allowed === true) return "allow";
  if (allowed === false) return "deny";
  return "skip_missing";
}

export function isMissingRpc(error: { message?: string; code?: string } | null): boolean {
  return interpretConsentGate({ data: null, error }) === "skip_missing";
}
