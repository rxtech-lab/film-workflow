import { reapExpiredReservations } from "@/lib/billing/repository";

export async function GET(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret || request.headers.get("authorization") !== `Bearer ${secret}`) return Response.json({ error: "Unauthorized" }, { status: 401 });
  const released = await reapExpiredReservations(new Date(Date.now() - 30 * 60 * 1000));
  return Response.json({ released });
}
