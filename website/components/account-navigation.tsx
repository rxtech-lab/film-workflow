"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { CreditCard, Gauge, ReceiptText, Sparkles } from "lucide-react";

const links = [
  { href: "/dashboard", label: "Dashboard", icon: Gauge },
  { href: "/credits", label: "Credits", icon: CreditCard },
  { href: "/usage", label: "Usage", icon: Sparkles },
  { href: "/invoices", label: "Invoices", icon: ReceiptText },
  { href: "/models", label: "Models", icon: Sparkles },
] as const;

export function AccountNavigation() {
  const pathname = usePathname();

  return (
    <nav className="mt-6 grid gap-1" aria-label="Account">
      {links.map(({ href, label, icon: Icon }) => {
        const isSelected = pathname === href || pathname.startsWith(`${href}/`);

        return (
          <Link
            key={href}
            href={href}
            aria-current={isSelected ? "page" : undefined}
            className={`flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm transition-colors ${
              isSelected
                ? "bg-accent/10 text-accent"
                : "text-muted hover:bg-elevated hover:text-fg"
            }`}
          >
            <Icon size={16} /> {label}
          </Link>
        );
      })}
    </nav>
  );
}
