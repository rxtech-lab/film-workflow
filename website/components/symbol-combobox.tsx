"use client";

import { ChevronDown } from "lucide-react";
import { useEffect, useId, useRef, useState, type KeyboardEvent } from "react";
import { SUGGESTED_SYMBOLS } from "@/lib/sf-symbols";
import { SfSymbol } from "./sf-symbol";

/** Search names on the server and load only the visible symbols' SVG previews. */
export function SymbolCombobox({ id, value, onChange, disabled, placeholder, describedBy }: {
  id: string;
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
  placeholder?: string;
  describedBy?: string;
}) {
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const [input, setInput] = useState({ selectedValue: value, query: value, edited: false });
  const [search, setSearch] = useState<{ query: string; results: string[]; loading: boolean; error: boolean }>({
    query: "", results: [], loading: false, error: false,
  });
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLUListElement>(null);
  const listId = useId();
  const query = input.selectedValue === value ? input.query : value;
  const searchQuery = query.trim();
  const hasCurrentSearch = search.query === searchQuery;
  const results = !searchQuery ? [...SUGGESTED_SYMBOLS] : hasCurrentSearch ? search.results : [];
  const loading = Boolean(searchQuery) && (!hasCurrentSearch || search.loading);
  const searchError = Boolean(searchQuery) && hasCurrentSearch && search.error;
  const expanded = open && !disabled;
  const activeIndex = Math.min(active, Math.max(0, results.length - 1));
  const activeOption = results[activeIndex];

  useEffect(() => {
    if (!expanded || !searchQuery) return;
    const controller = new AbortController();
    const timeout = window.setTimeout(async () => {
      setSearch({ query: searchQuery, results: [], loading: true, error: false });
      try {
        const response = await fetch(`/api/sf-symbols?q=${encodeURIComponent(searchQuery)}&limit=40`, { signal: controller.signal });
        if (!response.ok) throw new Error("Symbol search failed");
        const payload = await response.json() as { results?: unknown };
        if (!controller.signal.aborted) {
          setSearch({ query: searchQuery, results: Array.isArray(payload.results) ? payload.results.filter((name): name is string => typeof name === "string") : [], loading: false, error: false });
        }
      } catch {
        if (!controller.signal.aborted) setSearch({ query: searchQuery, results: [], loading: false, error: true });
      }
    }, 250);
    return () => { window.clearTimeout(timeout); controller.abort(); };
  }, [expanded, searchQuery]);

  useEffect(() => {
    if (!expanded) return;
    const list = listRef.current;
    const option = list?.querySelector<HTMLElement>(`[data-option-index="${activeIndex}"]`);
    if (!list || !option) return;
    const listBounds = list.getBoundingClientRect();
    const optionBounds = option.getBoundingClientRect();
    if (optionBounds.top < listBounds.top) list.scrollTop -= listBounds.top - optionBounds.top;
    else if (optionBounds.bottom > listBounds.bottom) list.scrollTop += optionBounds.bottom - listBounds.bottom;
  }, [activeIndex, activeOption, expanded]);

  function pick(name: string) {
    setInput({ selectedValue: name, query: name, edited: false });
    onChange(name);
    setOpen(false);
  }

  function finishEditing() {
    if (!query.trim() && input.edited) {
      setInput({ selectedValue: "", query: "", edited: false });
      onChange("");
    } else {
      setInput({ selectedValue: value, query: value, edited: false });
    }
    setOpen(false);
  }

  function onKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      setOpen(true);
      setActive(expanded ? Math.max(0, Math.min(results.length - 1, activeIndex + (event.key === "ArrowDown" ? 1 : -1))) : 0);
    } else if (event.key === "Enter" && expanded) {
      // Enter chooses an option; it must never submit the surrounding form during a search.
      event.preventDefault();
      if (activeOption && !loading && !searchError) pick(activeOption);
      else if (!searchQuery) pick("");
    } else if (event.key === "Escape" && expanded) {
      event.preventDefault();
      event.stopPropagation();
      setInput({ selectedValue: value, query: value, edited: false });
      setOpen(false);
    }
  }

  return (
    <div className="relative mt-1 min-w-0" onBlur={(event) => {
      if (!event.currentTarget.contains(event.relatedTarget as Node | null)) finishEditing();
    }}>
      <div className="flex items-center gap-2">
        <span className="flex size-9 shrink-0 items-center justify-center rounded-lg border border-line bg-elevated">
          <SfSymbol name={value || placeholder || ""} size={18} color="#f3f2ef" />
        </span>
        <div className="relative min-w-0 flex-1">
          <input
            ref={inputRef}
            id={id}
            role="combobox"
            aria-expanded={expanded}
            aria-haspopup="listbox"
            aria-controls={expanded ? listId : undefined}
            aria-autocomplete="list"
            aria-describedby={describedBy}
            aria-activedescendant={expanded && activeOption && !loading ? `${listId}-${activeIndex}` : undefined}
            className="w-full rounded-xl border border-line bg-elevated py-2 pr-8 pl-3 font-mono text-xs text-fg outline-none focus:border-accent disabled:opacity-40"
            value={query}
            placeholder={placeholder}
            maxLength={80}
            autoComplete="off"
            autoCapitalize="none"
            spellCheck={false}
            disabled={disabled}
            onFocus={() => { setOpen(true); setActive(0); }}
            onChange={(event) => { setActive(0); setOpen(true); setInput({ selectedValue: value, query: event.target.value, edited: true }); }}
            onKeyDown={onKeyDown}
          />
          <button
            type="button"
            tabIndex={-1}
            disabled={disabled}
            aria-label={expanded ? "Close symbol list" : "Browse symbols"}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => {
              inputRef.current?.focus();
              setOpen(!expanded);
              if (!expanded) { setActive(0); setInput({ selectedValue: value, query: "", edited: false }); }
              else setInput({ selectedValue: value, query: value, edited: false });
            }}
            className="absolute inset-y-0 right-1 flex w-6 items-center justify-center text-muted hover:text-fg disabled:opacity-40"
          ><ChevronDown size={14} aria-hidden="true" /></button>
        </div>
      </div>
      {expanded ? (
        <ul ref={listRef} id={listId} role="listbox" tabIndex={-1} aria-label="SF Symbols" aria-busy={loading}
          className="absolute inset-x-0 top-full z-30 mt-1 max-h-60 overflow-y-auto rounded-xl border border-line bg-surface p-1 shadow-xl">
          {loading || searchError || results.length === 0 ? (
            <li role="presentation" className="px-2 py-2 text-xs text-muted"><span role="status">{loading ? "Searching symbols…" : searchError ? "Symbol search is unavailable. Try again." : "No SF Symbols match this search."}</span></li>
          ) : results.map((name, index) => (
            <li key={name} id={`${listId}-${index}`} data-option-index={index} role="option" aria-selected={index === activeIndex}
              onMouseEnter={() => setActive(index)} onMouseDown={(event) => event.preventDefault()} onClick={() => pick(name)}
              className={`flex cursor-pointer items-center gap-2 rounded-lg px-2 py-2 text-xs ${index === activeIndex ? "bg-elevated text-accent" : "text-fg"}`}>
              <SfSymbol name={name} size={16} color={index === activeIndex ? "#ffb020" : "#f3f2ef"} />
              <span className="truncate font-mono">{name}</span>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
