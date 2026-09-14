import { requireAdminPageUser } from "@/lib/auth";

/** The nav only hides the link; this is the gate. */
export default async function AdminModelsLayout({ children }: { children: React.ReactNode }) {
  await requireAdminPageUser();
  return children;
}
