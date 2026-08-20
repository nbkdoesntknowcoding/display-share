/**
 * The update path, deliberately isolated from the rest of the app.
 *
 * v0.9.0 shipped a fault that threw during `main.ts` initialisation. The update
 * check lived further down the same module, so it never ran: the app could not
 * update itself out of the broken version, and every installation that took that
 * release was stranded until a human reinstalled by hand. A release that
 * disables its own escape hatch is the worst failure this project can ship,
 * because it cannot be repaired by shipping another one.
 *
 * So this module is imported FIRST and owns nothing else. It has no dependency
 * on any state in `main.ts`, touches only elements it looks up itself, and
 * catches everything. Whatever else breaks, an installation can still reach the
 * next release.
 *
 * Nothing here may import from `main.ts`, and nothing here may reach for a
 * variable it does not own — those are the two ways this guarantee gets lost.
 */
import { applyUpdate, checkForUpdate } from "./updater";

/// Resolved on use, never captured, so declaration order in any other module
/// cannot put this in a temporal dead zone — which is precisely how the fault it
/// exists to survive was introduced.
function banner(): HTMLElement | null {
  let bar = document.getElementById("update-bar");
  if (bar) return bar;
  bar = document.createElement("div");
  bar.id = "update-bar";
  document.body?.appendChild(bar);
  return bar;
}

/// True when the app is restarting to apply an update, so the caller can stop.
export async function selfHeal(): Promise<boolean> {
  // Logged unconditionally. When v0.9.0 bricked itself there was no way to tell
  // from the outside whether the update path had run and found nothing, or had
  // never run at all — and those need completely different fixes.
  console.info("self-heal: checking for updates");
  let status;
  try {
    status = await checkForUpdate();
  } catch (error) {
    // Offline, or the endpoint is unreachable. Never fatal: the app must still
    // run without a network.
    console.warn("update check failed", error);
    return false;
  }
  if (!status.available || !status.version) return false;

  const bar = banner();
  const label = document.createElement("span");
  label.textContent = `Updating to ${status.version}…`;
  bar?.replaceChildren(label);

  try {
    await applyUpdate((pct) => {
      label.textContent =
        pct < 100 ? `Updating to ${status.version}… ${pct}%` : "Restarting…";
    });
    return true;
  } catch (error) {
    label.textContent = `Update failed, continuing on this version: ${error}`;
    console.warn("update failed", error);
    return false;
  }
}

// Runs at import time, before the rest of the app has had a chance to fail.
// Deliberately not awaited: a slow or hanging check must not delay startup.
export const selfHealStarted = selfHeal().catch((error) => {
  console.warn("self-heal aborted", error);
  return false;
});
