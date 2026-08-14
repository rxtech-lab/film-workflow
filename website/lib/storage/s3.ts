import "server-only";

import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const MAX_UPLOAD_BYTES = 300 * 1024 * 1024;
const DEFAULT_PRESIGN_TTL_SECONDS = 15 * 60;

type StorageConfig = {
  bucket: string;
  publicURL: string | null;
  presignTTLSeconds: number;
};

let client: S3Client | null = null;

function required(name: string) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`STORAGE_NOT_CONFIGURED:${name}`);
  return value;
}

function config(): StorageConfig {
  const rawTTL = Number(process.env.S3_PRESIGN_TTL_SECONDS ?? DEFAULT_PRESIGN_TTL_SECONDS);
  return {
    bucket: required("S3_BUCKET"),
    publicURL: process.env.S3_PUBLIC_URL?.trim().replace(/\/+$/, "") || null,
    presignTTLSeconds: Number.isFinite(rawTTL) && rawTTL > 0
      ? Math.min(60 * 60, Math.floor(rawTTL))
      : DEFAULT_PRESIGN_TTL_SECONDS,
  };
}

// The SDK treats any path on the endpoint as a key prefix, so an endpoint that already names the
// bucket writes objects to `<bucket>/<key>`. publicObjectURL() has no such prefix, so every public
// URL would 404 while uploads silently succeed. Drop the segment when it duplicates the bucket.
function endpoint() {
  const configured = required("S3_ENDPOINT").replace(/\/+$/, "");
  const bucketSuffix = `/${required("S3_BUCKET")}`;
  return configured;
}

function s3() {
  if (client) return client;
  client = new S3Client({
    region: process.env.S3_REGION?.trim() || "auto",
    endpoint: endpoint(),
    forcePathStyle: process.env.S3_PATH_STYLE?.trim().toLowerCase() === "true",
    // The upload body is sent later by the native app. Avoid signing the
    // empty-body CRC32 that recent AWS SDK releases add by default.
    requestChecksumCalculation: "WHEN_REQUIRED",
    credentials: {
      accessKeyId: required("S3_ACCESS_KEY_ID"),
      secretAccessKey: required("S3_SECRET_ACCESS_KEY"),
    },
  });
  return client;
}

function encodedKey(key: string) {
  return key.split("/").map(encodeURIComponent).join("/");
}

function safeFilename(filename: string) {
  const normalized = filename.normalize("NFKC").replace(/[^a-zA-Z0-9._-]/g, "_");
  return normalized.replace(/^\.+/, "").slice(-120) || "upload";
}

export function transcriptionPrefix(userId: string) {
  return `transcriptions/${userId}/`;
}

export function ownsTranscriptionObject(userId: string, key: string) {
  return key.startsWith(transcriptionPrefix(userId)) && !key.includes("..") && !key.includes("\\");
}

export function publicObjectURL(key: string) {
  const publicURL = config().publicURL;
  if (!publicURL) return null;
  return `${publicURL}/${encodedKey(key)}`;
}

export async function createTranscriptionUpload(input: {
  userId: string;
  filename: string;
  contentType: string;
  sizeBytes: number;
}) {
  if (!Number.isInteger(input.sizeBytes) || input.sizeBytes <= 0 || input.sizeBytes > MAX_UPLOAD_BYTES) {
    throw new Error("INVALID_UPLOAD_SIZE");
  }
  const key = `${transcriptionPrefix(input.userId)}${crypto.randomUUID()}-${safeFilename(input.filename)}`;
  const storage = config();
  const uploadURL = await getSignedUrl(
    s3(),
    new PutObjectCommand({
      Bucket: storage.bucket,
      Key: key,
      ContentType: input.contentType,
      ContentLength: input.sizeBytes,
    }),
    { expiresIn: storage.presignTTLSeconds },
  );
  return {
    uploadURL,
    objectKey: key,
    headers: {
      "Content-Type": input.contentType,
      "Content-Length": String(input.sizeBytes),
    },
    expiresAt: new Date(Date.now() + storage.presignTTLSeconds * 1000),
  };
}

export async function putObject(input: { key: string; body: Buffer; contentType: string }) {
  const storage = config();
  await s3().send(new PutObjectCommand({
    Bucket: storage.bucket,
    Key: input.key,
    Body: input.body,
    ContentType: input.contentType,
    ContentLength: input.body.length,
  }));
  return { key: input.key, publicURL: publicObjectURL(input.key) };
}

export async function getObjectBytes(key: string, maximumBytes = MAX_UPLOAD_BYTES) {
  const storage = config();
  const head = await s3().send(new HeadObjectCommand({ Bucket: storage.bucket, Key: key }));
  if ((head.ContentLength ?? maximumBytes + 1) > maximumBytes) throw new Error("AUDIO_TOO_LARGE");
  const object = await s3().send(new GetObjectCommand({ Bucket: storage.bucket, Key: key }));
  if (!object.Body) throw new Error("STORAGE_OBJECT_EMPTY");
  const bytes = Buffer.from(await object.Body.transformToByteArray());
  if (bytes.length > maximumBytes) throw new Error("AUDIO_TOO_LARGE");
  return { bytes, contentType: object.ContentType || head.ContentType || "application/octet-stream" };
}

export async function deleteObject(key: string) {
  const storage = config();
  await s3().send(new DeleteObjectCommand({ Bucket: storage.bucket, Key: key }));
}

export async function objectDownloadURL(key: string) {
  const publicURL = publicObjectURL(key);
  if (publicURL) return publicURL;
  const storage = config();
  return getSignedUrl(
    s3(),
    new GetObjectCommand({ Bucket: storage.bucket, Key: key }),
    { expiresIn: storage.presignTTLSeconds },
  );
}

export const storageLimits = { maximumUploadBytes: MAX_UPLOAD_BYTES } as const;
