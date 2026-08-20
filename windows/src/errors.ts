/**
 * Turning transport failures into something a person can act on (Command 3).
 *
 * The receiver used to render Rust IO errors verbatim, including the Win32 code:
 *
 *   "connect to ws://192.168.29.8:8788 failed: IO error: No connection could be
 *    made because the target machine actively refused it. (os error 10061)"
 *
 * The audit called that the single most trust-destroying element in the product,
 * and it is right: it exposes the transport, the port, a Rust error type and an
 * OS error code, none of which the reader can do anything about.
 *
 * Rules encoded here:
 *   - never show a port number or a URL scheme in a user-facing message
 *   - always offer an action, because a message with no next step is a dead end
 *   - keep the raw text, but behind a disclosure, since bug reports need it
 */

export type ErrorAction = "retry" | "rescan" | "pair" | "update" | "copy";

export interface FriendlyError {
  /// Short headline, sentence case, no punctuation.
  headline: string;
  /// One line of guidance naming what the user should do.
  guidance: string;
  actions: ErrorAction[];
  /// The original message, kept for the collapsed technical disclosure.
  detail: string;
  /// True once retrying has stopped being plausible, which drives the colour:
  /// warn while it may still recover, error once it will not.
  terminal: boolean;
}

/// Matches on substrings rather than error types because the text crosses a
/// language boundary — Rust formats it, TypeScript receives it as a string.
export function humanise(raw: string): FriendlyError {
  const text = String(raw ?? "");
  const lower = text.toLowerCase();

  const has = (...needles: string[]) => needles.some((n) => lower.includes(n));

  if (has("10061", "econnrefused", "actively refused", "connection refused")) {
    return {
      headline: "Your Mac isn't sharing yet",
      guidance: "Open Display Share on your Mac and press Start.",
      actions: ["retry"],
      detail: text,
      terminal: false,
    };
  }
  if (has("10060", "etimedout", "timed out", "timeout", "unreachable", "no route")) {
    return {
      headline: "Can't reach that Mac",
      guidance: "Check both machines are on the same network.",
      actions: ["retry", "rescan"],
      detail: text,
      terminal: false,
    };
  }
  if (has("dns", "11001", "name resolution", "nodename", "not known", "failed to lookup")) {
    return {
      headline: "Couldn't find that Mac",
      guidance: "It may have gone offline since it was discovered.",
      actions: ["rescan"],
      detail: text,
      terminal: true,
    };
  }
  if (has("pair", "pin")) {
    return {
      headline: "Pairing declined",
      guidance: "Confirm the PIN shown on your Mac.",
      actions: ["pair"],
      detail: text,
      terminal: false,
    };
  }
  if (has("protocol version", "version mismatch", "unsupported version")) {
    return {
      headline: "Versions don't match",
      guidance: "Update both apps to the latest release.",
      actions: ["update"],
      detail: text,
      terminal: true,
    };
  }
  if (has("invalid authority", "invalid url", "relative url", "parse")) {
    return {
      headline: "That address doesn't look right",
      guidance: "Enter your Mac's IP address, for example 192.168.1.42.",
      actions: ["retry"],
      detail: text,
      terminal: true,
    };
  }
  return {
    headline: "Something went wrong",
    guidance: "The connection failed for an unexpected reason.",
    actions: ["retry", "copy"],
    detail: text,
    terminal: false,
  };
}

/// Guards the rule that a user-facing string never leaks transport detail.
///
/// Exported so it can be asserted in tests rather than left as an intention:
/// every headline and guidance string this module produces must pass.
export function leaksTransportDetail(message: string): boolean {
  return /\bws:\/\/|\bwss:\/\/|\bhttp:\/\/|:\d{4,5}\b|os error|\berrno\b/i.test(message);
}

export const RETRY_BACKOFF_MS = [1000, 2000, 4000];

/// How long to wait before attempt `n` (1-based), or null once retrying should
/// stop and the error state should be shown with a real action instead.
///
/// Retrying for ever hides the one thing that could fix it, which is exactly how
/// the pairing prompt ended up buried under "Retrying…".
export function backoffFor(attempt: number): number | null {
  if (attempt < 1) return RETRY_BACKOFF_MS[0];
  return attempt <= RETRY_BACKOFF_MS.length ? RETRY_BACKOFF_MS[attempt - 1] : null;
}
