import { and, eq } from "drizzle-orm";
import { aiRouteError, noStoreHeaders } from "@/lib/ai/http";
import { requireApiUser } from "@/lib/auth/bearer";
import { db } from "@/lib/db";
import { aiJobs } from "@/lib/db/schema";
import { objectDownloadURL } from "@/lib/storage/s3";

export async function GET(request: Request, { params }: { params: Promise<{ jobId: string }> }) {
  try {
    const user = await requireApiUser(request);
    const { jobId } = await params;
    const job = (await db.select().from(aiJobs).where(and(eq(aiJobs.id, jobId), eq(aiJobs.userId, user.id))).limit(1))[0];
    if (!job) return Response.json({ code: "not_found", error: "Job not found." }, { status: 404, headers: noStoreHeaders() });
    const resultUrl = job.status === "succeeded" && job.resultObjectKey ? await objectDownloadURL(job.resultObjectKey) : null;
    return Response.json({ id: job.id, status: job.status, progress_percent: job.progressPercent, result_url: resultUrl, result_meta: job.resultMeta, error: job.status === "failed" ? { code: job.errorCode, message: job.errorMessage } : null }, { headers: noStoreHeaders() });
  } catch (cause) { return aiRouteError(cause); }
}
