"use client";

import { useEffect, useRef, useState } from "react";

const secondary = "rounded-full border border-line px-4 py-2 text-sm hover:bg-elevated disabled:opacity-40";
const destructive = "rounded-full bg-red-500 px-4 py-2 text-sm font-medium text-white hover:bg-red-400 disabled:opacity-40";

/**
 * A modal that makes a destructive action deliberate.
 *
 * A native `<dialog>` rather than `window.confirm`: the browser dialog blocks
 * the whole page (and any automation driving it), and the marketplace forms
 * already established `showModal()` as the pattern here.
 *
 * `confirmPhrase` adds a second gate for the irreversible ones — the button
 * stays disabled until the phrase is typed, so "remove all" cannot be a stray
 * double-click on "remove".
 */
export function ConfirmDialog({ title, body, confirmLabel, confirmPhrase, pending, onConfirm, onClose }: {
  title: string;
  body: React.ReactNode;
  confirmLabel: string;
  confirmPhrase?: string;
  pending: boolean;
  onConfirm: () => void;
  onClose: () => void;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const [typed, setTyped] = useState("");
  const satisfied = !confirmPhrase || typed.trim().toLowerCase() === confirmPhrase.toLowerCase();

  useEffect(() => {
    const dialog = dialogRef.current;
    if (dialog && !dialog.open) dialog.showModal();
  }, []);

  return (
    <dialog
      ref={dialogRef}
      className="m-auto w-[min(28rem,calc(100vw-2rem))] rounded-2xl border border-line bg-surface p-0 text-fg shadow-2xl backdrop:bg-black/60 backdrop:backdrop-blur-sm"
      onClose={onClose}
      onCancel={(event) => { if (pending) event.preventDefault(); }}
      onClick={(event) => { if (event.target === event.currentTarget && !pending) event.currentTarget.close(); }}
      aria-labelledby="confirm-title"
    >
      <form
        className="p-6"
        onSubmit={(event) => { event.preventDefault(); if (satisfied && !pending) onConfirm(); }}
      >
        <h2 id="confirm-title" className="text-xl font-semibold">{title}</h2>
        <div className="mt-2 text-sm text-muted">{body}</div>
        {confirmPhrase ? (
          <label className="mt-5 block text-xs font-medium text-muted">
            Type <span className="font-mono text-fg">{confirmPhrase}</span> to confirm
            <input
              className="mt-1 w-full rounded-xl border border-line bg-elevated px-3 py-2 text-sm text-fg outline-none focus:border-accent"
              value={typed}
              onChange={(event) => setTyped(event.target.value)}
              autoComplete="off"
              spellCheck={false}
              disabled={pending}
              autoFocus
            />
          </label>
        ) : null}
        <div className="mt-6 flex justify-end gap-2">
          <button type="button" className={secondary} onClick={() => dialogRef.current?.close()} disabled={pending}>Cancel</button>
          <button type="submit" className={destructive} disabled={pending || !satisfied}>{pending ? "Removing…" : confirmLabel}</button>
        </div>
      </form>
    </dialog>
  );
}
