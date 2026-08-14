import Link from "next/link";
import { ArrowLeft, ArrowRight, LockKeyhole } from "lucide-react";
import { redirect } from "next/navigation";
import { authStatus, getCurrentUser, signIn } from "@/lib/auth";

export const metadata = { title: "Sign in · RxFilm Studio", robots: { index: false, follow: false } };

export default async function LoginPage() {
  if (await getCurrentUser()) redirect("/dashboard");

  async function authenticate() {
    "use server";
    await signIn("rxlab", { redirectTo: "/dashboard" });
  }

  return (
    <main className="min-h-screen bg-ink px-6 py-16 text-fg">
      <div className="mx-auto grid min-h-[70vh] max-w-5xl overflow-hidden rounded-3xl border border-line bg-surface md:grid-cols-2">
        <section className="flex flex-col justify-between bg-[radial-gradient(circle_at_top_left,rgba(255,176,32,.22),transparent_55%)] p-10">
          <Link className="font-mono text-xs tracking-[.24em] uppercase" href="/">RxFilm Studio</Link>
          <div><p className="font-mono text-xs text-accent uppercase">Account</p><h1 className="mt-4 text-5xl font-semibold tracking-tight">Your credits. Your studio.</h1></div>
        </section>
        <section className="flex flex-col justify-center p-10">
          <p className="font-mono text-xs tracking-[.2em] text-accent uppercase">RxLab identity</p>
          <h2 className="mt-3 text-3xl font-semibold">Sign in to continue.</h2>
          <p className="mt-4 text-muted">Use your RxLab account to manage credits, usage, invoices, and signed-in devices.</p>
          {!authStatus.configured ? <div className="mt-6 rounded-xl border border-amber-400/30 bg-amber-400/10 p-4 text-sm">Authentication is not configured. Add the RxLab OIDC environment values, or enable the development bypass locally.</div> : null}
          <form action={authenticate} className="mt-8"><button className="inline-flex items-center gap-2 rounded-full bg-accent px-5 py-3 font-medium text-black disabled:opacity-40" type="submit" disabled={!authStatus.configured}><LockKeyhole size={16} /> Continue with RxLab <ArrowRight size={16} /></button></form>
          <Link href="/" className="mt-6 inline-flex items-center gap-2 text-sm text-muted"><ArrowLeft size={14} /> Return to RxFilm Studio</Link>
        </section>
      </div>
    </main>
  );
}
