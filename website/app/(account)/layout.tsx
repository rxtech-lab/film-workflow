import { AccountShell } from "@/components/account-shell";
import { requirePageUser } from "@/lib/auth";
import { getBalance } from "@/lib/billing/subscription";

export default async function AccountLayout({ children }: { children: React.ReactNode }) {
  const user = await requirePageUser();
  // The shell renders a balance, not a catalog, so this stays a single call.
  const balance = await getBalance(user);
  return <AccountShell user={user} balance={balance.available}>{children}</AccountShell>;
}
