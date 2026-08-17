import { check } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";

/**
 * Update check against GitHub Releases.
 *
 * Deliberately manual-first: it checks on launch and reports, but never
 * downloads without the user agreeing. Display Share ships unsigned, so a
 * silent auto-update would be exactly the behaviour a user should be
 * suspicious of.
 */
export interface UpdateStatus {
  available: boolean;
  version?: string;
  notes?: string;
  error?: string;
}

export async function checkForUpdate(): Promise<UpdateStatus> {
  try {
    const update = await check();
    if (!update) return { available: false };
    return { available: true, version: update.version, notes: update.body };
  } catch (e) {
    // No releases published yet returns a 404, which is not an error worth
    // showing the user — it is the normal state before the first release.
    const message = String(e);
    if (message.includes("404") || message.toLowerCase().includes("not found")) {
      return { available: false };
    }
    return { available: false, error: message };
  }
}

/** Downloads and installs, then relaunches. Only call after the user agrees. */
export async function applyUpdate(onProgress?: (pct: number) => void): Promise<void> {
  const update = await check();
  if (!update) return;

  let downloaded = 0;
  let total = 0;
  await update.downloadAndInstall((event) => {
    switch (event.event) {
      case "Started":
        total = event.data.contentLength ?? 0;
        break;
      case "Progress":
        downloaded += event.data.chunkLength;
        if (total > 0) onProgress?.(Math.round((downloaded / total) * 100));
        break;
      case "Finished":
        onProgress?.(100);
        break;
    }
  });
  await relaunch();
}
