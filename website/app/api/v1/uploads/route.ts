import { z } from "zod";
import { requireApiUser, UnauthorizedError, unauthorizedResponse } from "@/lib/auth/bearer";
import { createTranscriptionUpload, storageLimits } from "@/lib/storage/s3";

const schema = z.object({
  filename: z.string().min(1).max(255),
  content_type: z.string().min(1).max(150).refine((value) =>
    value.startsWith("audio/") || value === "video/mp4" || value === "video/quicktime",
  ),
  size_bytes: z.number().int().positive().max(storageLimits.maximumUploadBytes),
});

export async function POST(request: Request) {
  try {
    const user = await requireApiUser(request);
    const parsed = schema.safeParse(await request.json().catch(() => null));
    if (!parsed.success) {
      return Response.json(
        { code: "bad_request", error: parsed.error.issues[0]?.message ?? "Invalid upload request." },
        { status: 400, headers: { "Cache-Control": "private, no-store" } },
      );
    }
    const upload = await createTranscriptionUpload({
      userId: user.id,
      filename: parsed.data.filename,
      contentType: parsed.data.content_type,
      sizeBytes: parsed.data.size_bytes,
    });
    return Response.json({
      upload_url: upload.uploadURL,
      object_key: upload.objectKey,
      headers: upload.headers,
      expires_at: upload.expiresAt.toISOString(),
    }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (cause) {
    if (cause instanceof UnauthorizedError) return unauthorizedResponse();
    const code = cause instanceof Error ? cause.message : "UPLOAD_TOKEN_FAILED";
    console.error("S3 upload authorization failed", { code });
    const status = code.startsWith("STORAGE_NOT_CONFIGURED:") ? 503 : 400;
    return Response.json({ code: "upload_failed", error: "The upload could not be authorized." }, { status, headers: { "Cache-Control": "private, no-store" } });
  }
}
