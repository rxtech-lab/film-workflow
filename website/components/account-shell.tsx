import Link from "next/link";
import { LogOut } from "lucide-react";
import { AccountNavigation } from "@/components/account-navigation";
import { signOut, type AppUser } from "@/lib/auth";

export function AccountShell({ user, balance, children }: { user: AppUser; balance: number; children: React.ReactNode }) {
  async function logout() {
    "use server";
    await signOut({ redirectTo: "/" });
  }
  return (
    <main className="min-h-screen bg-ink text-fg md:grid md:grid-cols-[250px_1fr]">
      <aside className="border-b border-line bg-surface p-6 md:sticky md:top-0 md:h-screen md:border-r md:border-b-0">
        <Link href="/" className="font-mono text-xs tracking-[.22em] uppercase">RxFilm Studio</Link>
        <div className="mt-8 rounded-2xl border border-line bg-elevated p-4"><p className="text-xs text-muted">Available credits</p><strong className="mt-1 block text-3xl tabular-nums">{balance.toLocaleString("en-US")}</strong></div>
        <AccountNavigation />
        <div className="mt-8 border-t border-line pt-5"><p className="truncate text-sm">{user.email || user.name}</p><form action={logout}><button className="mt-3 inline-flex items-center gap-2 text-sm text-muted hover:text-fg" type="submit"><LogOut size={14} /> Sign out</button></form></div>
      </aside>
      <div className="min-w-0 p-6 md:p-10">{children}</div>
    </main>
  );
}
