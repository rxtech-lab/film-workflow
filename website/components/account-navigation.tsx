"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { CreditCard, Gauge, ReceiptText, Sparkles, SlidersHorizontal, Store } from "lucide-react";

const links = [
  { href: "/dashboard", label: "Dashboard", icon: Gauge },
  { href: "/credits", label: "Credits", icon: CreditCard },
  { href: "/usage", label: "Usage", icon: Sparkles },
  { href: "/invoices", label: "Invoices", icon: ReceiptText },
  { href: "/models", label: "Models", icon: Sparkles },
] as const;

const adminLinks = [
  { href: "/admin/marketplace", label: "Marketplace", icon: Store },
  // "Model catalog" rather than "Models": /models is already above, and two rows reading the same word is not a menu.
  { href: "/admin/models", label: "Model catalog", icon: SlidersHorizontal },
] as const;

type NavLink = { href: string; label: string; icon: typeof Gauge };

function NavItem({ link, pathname }: { link: NavLink; pathname: string }) {
  const { href, label, icon: Icon } = link;
  const isSelected = pathname === href || pathname.startsWith(`${href}/`);

  return (
    <Link
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
}

export function AccountNavigation({ isAdmin = false }: { isAdmin?: boolean }) {
  const pathname = usePathname();

  return (
    <nav className="mt-6 grid gap-1" aria-label="Account">
      {links.map((link) => <NavItem key={link.href} link={link} pathname={pathname} />)}
      {/* The admin pages act on everyone's data, so they are set apart rather than mixed into the account rows. */}
      {isAdmin ? (
        <>
          <hr className="mt-3 border-line" />
          <p className="px-3 pt-3 pb-1 font-mono text-xs tracking-[.2em] text-muted uppercase">Admin</p>
          {adminLinks.map((link) => <NavItem key={link.href} link={link} pathname={pathname} />)}
        </>
      ) : null}
    </nav>
  );
}
