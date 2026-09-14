"use client";

import { useId } from "react";
import { DEFAULT_CATEGORY_ICON } from "@/lib/marketplace/schema";
import { SymbolCombobox } from "./symbol-combobox";

export function IconField({ value, onChange, disabled, className }: {
  value: string;
  onChange: (icon: string) => void;
  disabled: boolean;
  className?: string;
}) {
  const id = useId();
  return (
    <div className={`mt-4 min-w-0 ${className ?? ""}`}>
      <label htmlFor={id} className="block text-xs font-medium text-muted">Icon (SF Symbol)</label>
      <SymbolCombobox id={id} value={value} onChange={onChange} disabled={disabled} placeholder={DEFAULT_CATEGORY_ICON} describedBy={`${id}-hint`} />
      <p id={`${id}-hint`} className="mt-1 text-xs text-muted">Search and select a symbol. Clear to use <span className="font-mono">{DEFAULT_CATEGORY_ICON}</span>.</p>
    </div>
  );
}
