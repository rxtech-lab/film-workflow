"use client";

import { useEffect, useId, useMemo, useRef, useState } from "react";

export type SearchableOption = {
  value: string;
  label: string;
  /** Shown under the label in monospace — the model id, so the admin can tell siblings apart. */
  hint?: string;
  /** Shown on the right, e.g. an estimated credit cost. */
  detail?: string;
};

const field = "w-full rounded-xl border border-line bg-elevated px-3 py-2 text-sm text-fg outline-none focus:border-accent";

/**
 * A text field that filters a list and commits one option.
 *
 * Hand-rolled because the project carries no component library: the other
 * pickers here are raw `<select>`, which cannot search and cannot show a second
 * line per option. The whole option list is passed in and filtered in memory —
 * a few hundred models is nowhere near enough to justify a debounced round trip.
 */
export function SearchableSelect({ options, onSelect, placeholder, disabled, emptyLabel = "No matches." }: {
  options: SearchableOption[];
  onSelect: (value: string) => void;
  placeholder?: string;
  disabled?: boolean;
  emptyLabel?: string;
}) {
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const listId = useId();
  const root = useRef<HTMLDivElement>(null);
  const activeRef = useRef<HTMLLIElement>(null);

  const matches = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return options;
    return options.filter((option) =>
      option.label.toLowerCase().includes(needle) || option.value.toLowerCase().includes(needle));
  }, [options, query]);

  useEffect(() => { activeRef.current?.scrollIntoView({ block: "nearest" }); }, [active, open]);

  // Clicking anywhere else closes the list; blur alone would fire before a click on an option registers.
  useEffect(() => {
    if (!open) return;
    function onPointerDown(event: PointerEvent) {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    }
    document.addEventListener("pointerdown", onPointerDown);
    return () => document.removeEventListener("pointerdown", onPointerDown);
  }, [open]);

  function commit(index: number) {
    const option = matches[index];
    if (!option) return;
    onSelect(option.value);
    setQuery("");
    setOpen(false);
  }

  function onKeyDown(event: React.KeyboardEvent<HTMLInputElement>) {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (!open) { setOpen(true); return; }
      if (matches.length === 0) return;
      const step = event.key === "ArrowDown" ? 1 : -1;
      setActive((current) => (current + step + matches.length) % matches.length);
      return;
    }
    if (event.key === "Enter" && open) { event.preventDefault(); commit(active); return; }
    if (event.key === "Escape" && open) { event.preventDefault(); setOpen(false); setQuery(""); }
  }

  return (
    <div className="relative" ref={root}>
      <input
        className={field}
        type="text"
        role="combobox"
        aria-expanded={open}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={open && matches[active] ? `${listId}-${active}` : undefined}
        autoComplete="off"
        spellCheck={false}
        placeholder={placeholder}
        value={query}
        disabled={disabled}
        onChange={(event) => { setQuery(event.target.value); setActive(0); setOpen(true); }}
        onFocus={() => setOpen(true)}
        onKeyDown={onKeyDown}
      />
      {open ? (
        <ul
          id={listId}
          role="listbox"
          className="absolute z-20 mt-1 max-h-72 w-full overflow-y-auto rounded-xl border border-line bg-elevated py-1 shadow-lg"
        >
          {matches.length === 0
            ? <li className="px-3 py-2 text-sm text-muted">{emptyLabel}</li>
            : matches.map((option, index) => (
              <li
                key={option.value}
                id={`${listId}-${index}`}
                ref={index === active ? activeRef : undefined}
                role="option"
                aria-selected={index === active}
                className={`flex cursor-pointer items-baseline justify-between gap-3 px-3 py-2 ${index === active ? "bg-accent/10 text-accent" : "text-fg"}`}
                onPointerMove={() => setActive(index)}
                onClick={() => commit(index)}
              >
                <span className="min-w-0">
                  <strong className="block truncate text-sm font-medium">{option.label}</strong>
                  {option.hint ? <small className="block truncate font-mono text-xs text-muted">{option.hint}</small> : null}
                </span>
                {option.detail ? <small className="shrink-0 text-xs text-muted">{option.detail}</small> : null}
              </li>
            ))}
        </ul>
      ) : null}
    </div>
  );
}
