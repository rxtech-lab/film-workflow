import { AccountShell } from "@/components/account-shell";
import { requirePageUser } from "@/lib/auth";
import { getBillingSummary } from "@/lib/billing/repository";

export default async function AccountLayout({ children }: { children: React.ReactNode }) {
  const user = await requirePageUser();
  const summary = await getBillingSummary(user.id);
  return <AccountShell user={user} balance={summary.availablePoints}>{children}</AccountShell>;
}
