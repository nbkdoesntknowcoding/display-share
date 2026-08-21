/**
 * What the receiver's window looks like in each state (Command 10).
 *
 * The audit found the transition from connect card to canvas undefined:
 * `display: none` cannot animate, so connecting was a hard cut to black, and a
 * session that dropped replaced the picture with an empty window — which reads
 * as the app breaking rather than the link dropping.
 *
 * The decision lives here, as a pure function, rather than as six
 * `classList.toggle` calls inside an event handler. Those calls are only
 * reachable through a live WebSocket and a decoded frame, so nothing could
 * check them without a Mac at the other end; this can be checked with an
 * object.
 */

export interface WindowState {
  /// Whether the connect card is up.
  overlayVisible: boolean;
  /// Whether a frame has ever been painted. What separates "not connected yet"
  /// from "was connected and lost it" — identical to the code that raises the
  /// card, and it must not be identical to the user.
  hasLiveFrame: boolean;
  /// The user's HUD preference, which survives a reconnect.
  hudWanted: boolean;
}

export interface WindowClasses {
  overlay: string[];
  canvas: string[];
  /// The app mark and wordmark, outside the card.
  mark: string[];
  hud: string[];
}

export function windowClasses(state: WindowState): WindowClasses {
  const { overlayVisible, hasLiveFrame, hudWanted } = state;

  // The card is over a session only when there is a picture behind it to dim.
  // At startup there is nothing behind it, so it IS the window.
  const overSession = overlayVisible && hasLiveFrame;

  return {
    overlay: [...(overlayVisible ? [] : ["hidden"]), ...(overSession ? ["over-session"] : [])],
    canvas: [...(hasLiveFrame ? ["live"] : []), ...(overSession ? ["dimmed"] : [])],
    // Zero chrome while streaming: the identity belongs to the connect screen.
    mark: overlayVisible ? [] : ["hidden"],
    // The HUD describes a live stream, so it goes while the card is up — and
    // must come back when the stream returns. Hiding it without restoring it
    // left the HUD gone for a whole session, needing two presses of H.
    hud: !overlayVisible && hudWanted ? [] : ["hidden"],
  };
}

/// Applies the classes for a state, leaving every other class alone.
export function applyWindowClasses(
  elements: {
    overlay: HTMLElement | null;
    canvas: HTMLElement | null;
    mark: HTMLElement | null;
    hud: HTMLElement | null;
  },
  state: WindowState
): void {
  const wanted = windowClasses(state);
  const all: Record<keyof WindowClasses, string[]> = {
    overlay: ["hidden", "over-session"],
    canvas: ["live", "dimmed"],
    mark: ["hidden"],
    hud: ["hidden"],
  };
  for (const key of Object.keys(all) as (keyof WindowClasses)[]) {
    const element = elements[key];
    if (!element) continue;
    for (const name of all[key]) {
      element.classList.toggle(name, wanted[key].includes(name));
    }
  }
}
