import "server-only";
import { neon } from "@neondatabase/serverless";
import { drizzle, type NeonHttpDatabase } from "drizzle-orm/neon-http";
import * as schema from "./schema";

type Database = NeonHttpDatabase<typeof schema>;

let instance: Database | null = null;

/**
 * Connected on first use rather than at import, so a module that merely
 * imports the database — a page whose render never reaches a query, a test
 * that mocks it — does not need `DATABASE_URL` set.
 */
function connect(): Database {
  if (instance) return instance;
  const url = process.env.DATABASE_URL?.trim();
  if (!url) throw new Error("DATABASE_URL_NOT_CONFIGURED");
  instance = drizzle(neon(url), { schema });
  return instance;
}

export const db: Database = new Proxy({} as Database, {
  get(_target, property, receiver) {
    const value = Reflect.get(connect(), property, receiver);
    return typeof value === "function" ? value.bind(instance) : value;
  },
});
