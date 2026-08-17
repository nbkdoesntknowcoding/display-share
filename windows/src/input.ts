/**
 * Receiver-side input capture (protocol/SPEC.md §4.10).
 *
 * Two things here are easy to get wrong and are the reason this is its own file:
 *
 * 1. **Coordinates are normalised against the displayed VIDEO rect, not the
 *    window.** The canvas is letterboxed whenever the window aspect differs from
 *    the stream, so window-relative coordinates would be offset by the bars and
 *    land in the wrong place on the Mac.
 * 2. **Events are batched per animation frame.** A moving mouse generates events
 *    far faster than 60 Hz, and one WebSocket text frame each would compete with
 *    video on the same socket.
 */

export interface InputEvent {
  k: "move" | "down" | "up" | "scroll" | "key";
  t: number;
  x?: number;
  y?: number;
  b?: number;
  dx?: number;
  dy?: number;
  code?: string;
  down?: boolean;
  mods?: { shift: boolean; ctrl: boolean; alt: boolean; meta: boolean };
}

export interface InputCaptureOptions {
  canvas: HTMLCanvasElement;
  /** Called with a batch, at most once per animation frame. */
  send: (events: InputEvent[]) => void;
  /** Fired when forwarding is toggled, so the UI can reflect it. */
  onEnabledChanged?: (enabled: boolean) => void;
}

export class InputCapture {
  private enabled = false;
  private queue: InputEvent[] = [];
  private flushScheduled = false;
  private readonly origin = performance.now();
  private readonly canvas: HTMLCanvasElement;
  private readonly send: (events: InputEvent[]) => void;
  private readonly onEnabledChanged?: (enabled: boolean) => void;

  constructor(options: InputCaptureOptions) {
    this.canvas = options.canvas;
    this.send = options.send;
    this.onEnabledChanged = options.onEnabledChanged;
    this.attach();
  }

  get isEnabled(): boolean {
    return this.enabled;
  }

  setEnabled(value: boolean) {
    if (this.enabled === value) return;
    this.enabled = value;
    if (!value) {
      // Drop anything queued: replaying stale motion after re-enabling would
      // jump the cursor.
      this.queue.length = 0;
    }
    this.onEnabledChanged?.(value);
  }

  toggle() {
    this.setEnabled(!this.enabled);
  }

  private stamp(): number {
    return Math.round(performance.now() - this.origin);
  }

  private enqueue(event: InputEvent) {
    if (!this.enabled) return;
    this.queue.push(event);
    if (!this.flushScheduled) {
      this.flushScheduled = true;
      requestAnimationFrame(() => {
        this.flushScheduled = false;
        if (this.queue.length === 0) return;
        const batch = this.queue;
        this.queue = [];
        this.send(batch);
      });
    }
  }

  /**
   * Maps a pointer position to 0-1 within the video rectangle.
   *
   * The canvas element fills the window but the *image* inside it is fitted with
   * `object-fit: contain`, so the drawn rect is centred with bars on one axis.
   * Returns null when the pointer is over a bar rather than the video.
   */
  private normalise(clientX: number, clientY: number): { x: number; y: number } | null {
    const rect = this.canvas.getBoundingClientRect();
    const videoWidth = this.canvas.width;
    const videoHeight = this.canvas.height;
    if (videoWidth === 0 || videoHeight === 0 || rect.width === 0 || rect.height === 0) return null;

    const scale = Math.min(rect.width / videoWidth, rect.height / videoHeight);
    const drawnWidth = videoWidth * scale;
    const drawnHeight = videoHeight * scale;
    const offsetX = rect.left + (rect.width - drawnWidth) / 2;
    const offsetY = rect.top + (rect.height - drawnHeight) / 2;

    const x = (clientX - offsetX) / drawnWidth;
    const y = (clientY - offsetY) / drawnHeight;
    // Outside the video: the pointer is on a letterbox bar. Drop rather than
    // clamp, or the cursor would stick to the display edge.
    if (x < 0 || x > 1 || y < 0 || y > 1) return null;
    return { x, y };
  }

  private modifiers(event: KeyboardEvent | MouseEvent) {
    return {
      shift: event.shiftKey,
      ctrl: event.ctrlKey,
      alt: event.altKey,
      meta: event.metaKey,
    };
  }

  private attach() {
    this.canvas.addEventListener("mousemove", (event) => {
      const point = this.normalise(event.clientX, event.clientY);
      if (!point) return;
      this.enqueue({ k: "move", x: point.x, y: point.y, t: this.stamp() });
    });

    this.canvas.addEventListener("mousedown", (event) => {
      const point = this.normalise(event.clientX, event.clientY);
      if (!point) return;
      // Send position with the press so a click never lands where the last
      // move event happened to leave the cursor.
      this.enqueue({ k: "move", x: point.x, y: point.y, t: this.stamp() });
      this.enqueue({ k: "down", b: event.button, t: this.stamp() });
      event.preventDefault();
    });

    this.canvas.addEventListener("mouseup", (event) => {
      this.enqueue({ k: "up", b: event.button, t: this.stamp() });
      event.preventDefault();
    });

    // Without this, right-click opens the webview's own context menu instead of
    // reaching the Mac.
    this.canvas.addEventListener("contextmenu", (event) => {
      if (this.enabled) event.preventDefault();
    });

    this.canvas.addEventListener(
      "wheel",
      (event) => {
        if (!this.enabled) return;
        // deltaMode 0 is pixels, 1 lines, 2 pages. Normalise to line-ish units
        // so the Mac side can post a sensible scroll wheel event.
        const divisor = event.deltaMode === 0 ? 40 : 1;
        this.enqueue({
          k: "scroll",
          dx: -event.deltaX / divisor,
          dy: -event.deltaY / divisor,
          t: this.stamp(),
        });
        event.preventDefault();
      },
      { passive: false }
    );

    // Keyboard is on the window: the canvas cannot hold focus reliably.
    window.addEventListener("keydown", (event) => this.handleKey(event, true));
    window.addEventListener("keyup", (event) => this.handleKey(event, false));

    // Losing focus must release everything, or a held modifier stays stuck down
    // on the Mac with no event coming to clear it.
    window.addEventListener("blur", () => this.releaseAll());
  }

  private heldKeys = new Set<string>();

  private handleKey(event: KeyboardEvent, down: boolean) {
    if (!this.enabled) return;
    // The toggle hotkey belongs to the receiver and must never be forwarded.
    if (event.code === "F8") return;

    if (down) this.heldKeys.add(event.code);
    else this.heldKeys.delete(event.code);

    this.enqueue({
      k: "key",
      code: event.code,
      down,
      mods: this.modifiers(event),
      t: this.stamp(),
    });
    event.preventDefault();
  }

  /** Sends key-up for everything still held. Called on blur and on disable. */
  releaseAll() {
    if (this.heldKeys.size === 0) return;
    const held = [...this.heldKeys];
    this.heldKeys.clear();
    // Force the batch out even if forwarding was just turned off — a stuck
    // modifier on the Mac is worse than one extra message.
    const wasEnabled = this.enabled;
    this.enabled = true;
    for (const code of held) {
      this.enqueue({
        k: "key",
        code,
        down: false,
        mods: { shift: false, ctrl: false, alt: false, meta: false },
        t: this.stamp(),
      });
    }
    this.enabled = wasEnabled;
  }
}
