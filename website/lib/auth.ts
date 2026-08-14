import NextAuth from "next-auth";
import { createRxLabAuth, RX_LAB_REFRESH_TOKEN_ERROR } from "@rxtech-lab/authjs-rxlab";
import { redirect } from "next/navigation";

const rxLabConfigured = Boolean(
  process.env.AUTH_ISSUER &&
  process.env.AUTH_CLIENT_ID &&
  process.env.AUTH_CLIENT_SECRET &&
  process.env.AUTH_SECRET,
);

const authResult = rxLabConfigured
  ? createRxLabAuth({
      issuer: process.env.AUTH_ISSUER!,
      clientId: process.env.AUTH_CLIENT_ID!,
      clientSecret: process.env.AUTH_CLIENT_SECRET!,
      signInPage: "/login",
      trustHost: true,
    })
  : NextAuth({ providers: [], trustHost: true, secret: process.env.AUTH_SECRET ?? "local-development-only-secret-change-me" });

export const { handlers, signIn, signOut, auth } = authResult;
export { RX_LAB_REFRESH_TOKEN_ERROR };

export type AppUser = {
  id: string;
  name: string;
  email: string;
  roles: string[];
  isDevelopmentBypass?: boolean;
};

export const isDevelopmentBypass =
  process.env.NODE_ENV !== "production" && process.env.DEV_BYPASS_AUTH === "true";

export async function getCurrentUser(): Promise<AppUser | null> {
  if (isDevelopmentBypass) {
    return {
      id: "local-development-user",
      name: "Local founder",
      email: "founder@local.test",
      roles: ["user"],
      isDevelopmentBypass: true,
    };
  }
  if (!rxLabConfigured) return null;
  const session = await auth();
  if (!session?.user?.id) return null;
  return {
    id: session.user.id,
    name: session.user.name ?? "Founder",
    email: session.user.email ?? "",
    roles: session.user.roles ?? [],
  };
}

export async function requirePageUser() {
  const user = await getCurrentUser();
  if (!user) redirect("/login");
  return user;
}

export const authStatus = {
  configured: rxLabConfigured,
  developmentBypass: isDevelopmentBypass,
};
