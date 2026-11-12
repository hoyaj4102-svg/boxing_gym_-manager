export function extractTossReceiptUrl(payload: unknown): string | null {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return null;
  const receipt = (payload as { receipt?: unknown }).receipt;
  if (!receipt || typeof receipt !== "object" || Array.isArray(receipt)) return null;
  const url = (receipt as { url?: unknown }).url;
  if (typeof url !== "string") return null;

  try {
    const parsed = new URL(url);
    const host = parsed.hostname.toLowerCase();
    const tossHost = host === "tosspayments.com" || host.endsWith(".tosspayments.com");
    if (parsed.protocol !== "https:" || !tossHost) return null;
    return parsed.toString();
  } catch {
    return null;
  }
}
