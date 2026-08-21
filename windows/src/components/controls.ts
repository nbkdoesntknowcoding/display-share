/**
 * The receiver's button and input helpers (Command 7 of the UI/UX audit).
 *
 * The look lives in src/styles/controls.css — this file is only the behaviour
 * that cannot be expressed in CSS, and it is deliberately small. There is no
 * second copy of the variant rules here: scripts/check-controls.py reads the
 * stylesheet for the list of variants and checks the markup against it, so
 * adding a variant in one place cannot silently disagree with the other.
 *
 * The one behaviour worth stating: **buttons are never natively `disabled`.**
 * A disabled control is removed from the tab order and, in Chromium, receives
 * no pointer events — so its `title` never appears. That combination means the
 * explanation for why a button cannot be pressed is unreachable by keyboard
 * users and by anyone hovering it, which is precisely who needed it. The audit
 * asks for "40% opacity + tooltip explaining why"; the tooltip only exists if
 * the element stays live, so `aria-disabled` carries the state and the guard
 * below swallows the interaction.
 */

export type ButtonVariant = "primary" | "secondary" | "ghost" | "destructive" | "row";

/// Kept in the order the audit lists them, loudest first. `row` is the
/// full-width list entry used for a discovered device.
export const BUTTON_VARIANTS: readonly ButtonVariant[] = [
  "primary",
  "secondary",
  "ghost",
  "destructive",
  "row",
];

export interface ButtonOptions {
  variant: ButtonVariant;
  /// The single tallest action on a screen. At most one may be hero.
  hero?: boolean;
}

export function classesFor({ variant, hero = false }: ButtonOptions): string[] {
  const classes = ["btn", `btn--${variant}`];
  if (hero) classes.push("btn--hero");
  return classes;
}

export function createButton(label: string, options: ButtonOptions): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = classesFor(options).join(" ");
  button.textContent = label;
  return button;
}

/**
 * Enables or disables a control without removing it from the interface.
 *
 * `reason` is required to disable, because a control that cannot be pressed and
 * does not say why is a dead end — the same failure the error messages had
 * before Command 3.
 */
export function setEnabled(
  button: HTMLElement | null,
  enabled: boolean,
  reason?: string
): void {
  if (!button) return;
  if (enabled) {
    button.removeAttribute("aria-disabled");
    button.removeAttribute("title");
    return;
  }
  button.setAttribute("aria-disabled", "true");
  if (reason) button.setAttribute("title", reason);
}

export function isEnabled(button: HTMLElement | null): boolean {
  return button?.getAttribute("aria-disabled") !== "true";
}

/**
 * Moves a control to a different variant, leaving every other class alone.
 *
 * Exists because "exactly one primary action" is a property of the SCREEN, not
 * of a button: select a discovered Mac and then open manual entry, and two
 * accent Connect buttons appear side by side, each claiming to be the one
 * thing to press. Whichever path is currently recommended holds the primary.
 */
export function setVariant(el: HTMLElement | null, variant: ButtonVariant): void {
  if (!el) return;
  for (const name of BUTTON_VARIANTS) el.classList.remove(`btn--${name}`);
  el.classList.add(`btn--${variant}`);
}

/// Every primary button currently on screen. More than one is a bug.
export function visiblePrimaries(root: ParentNode = document): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(".btn--primary")).filter(
    (el) => el.offsetParent !== null
  );
}

/**
 * Swallows interaction with anything marked `aria-disabled`.
 *
 * Capture phase and `stopImmediatePropagation`, so it holds no matter which
 * listener was attached first or by whom — the guarantee has to be a property
 * of the page rather than a convention every call site remembers.
 */
export function installDisabledGuard(root: Document = document): void {
  const blocked = (event: Event) => {
    const target = event.target as HTMLElement | null;
    if (!target?.closest?.('[aria-disabled="true"]')) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  };
  root.addEventListener("click", blocked, true);
  root.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") blocked(event);
  }, true);
}
