import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { getSiteUrl } from "./lib/site";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

const title = "RxFilmStudio — Your film studio, in one window";
const description =
  "A native macOS app to score, narrate, caption, and render your film — with an agent in the director's chair.";

export const metadata: Metadata = {
  metadataBase: new URL(getSiteUrl()),
  title,
  description,
  alternates: { canonical: "/" },
  applicationName: "RxFilmStudio",
  keywords: [
    "RxFilmStudio",
    "film workflow",
    "macOS",
    "AI music generation",
    "narration",
    "captions",
    "Remotion",
  ],
  openGraph: {
    title,
    description,
    type: "website",
    siteName: "RxFilmStudio",
    url: "/",
  },
  twitter: {
    card: "summary_large_image",
    title,
    description,
  },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
