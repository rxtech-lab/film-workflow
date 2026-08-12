import { ImageResponse } from "next/og";
import { getLatestRelease } from "./lib/release";

export const alt =
  "RxFilmStudio — your film studio, in one window. Native macOS app.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

function Rail() {
  return (
    <div
      style={{
        display: "flex",
        justifyContent: "space-between",
        width: "100%",
        padding: "0 40px",
      }}
    >
      {Array.from({ length: 14 }).map((_, i) => (
        <div
          key={i}
          style={{
            width: 44,
            height: 18,
            borderRadius: 5,
            background: "#1c2024",
          }}
        />
      ))}
    </div>
  );
}

export default async function OpengraphImage() {
  const release = await getLatestRelease();

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          background: "#08090a",
          padding: "40px 0",
        }}
      >
        <Rail />

        <div
          style={{
            display: "flex",
            flexDirection: "column",
            padding: "0 80px",
          }}
        >
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 18,
              marginBottom: 34,
            }}
          >
            <div
              style={{
                width: 30,
                height: 30,
                borderRadius: 8,
                background: "#ffb020",
              }}
            />
            <div
              style={{
                fontSize: 22,
                letterSpacing: 6,
                color: "#8b8f95",
                textTransform: "uppercase",
              }}
            >
              RxFilmStudio
            </div>
          </div>

          <div
            style={{
              display: "flex",
              flexDirection: "column",
              fontSize: 88,
              fontWeight: 700,
              letterSpacing: -3,
              lineHeight: 1.05,
              color: "#f3f2ef",
            }}
          >
            <div style={{ display: "flex" }}>Your film studio,</div>
            <div style={{ display: "flex", color: "#ffb020" }}>
              in one window.
            </div>
          </div>

          <div
            style={{
              display: "flex",
              fontSize: 30,
              color: "#8b8f95",
              marginTop: 30,
            }}
          >
            Score · Narrate · Caption · Render
          </div>
        </div>

        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            padding: "0 80px",
          }}
        >
          <div
            style={{
              display: "flex",
              fontSize: 24,
              letterSpacing: 3,
              color: "#8b8f95",
              textTransform: "uppercase",
            }}
          >
            Native macOS
          </div>
          <div
            style={{
              display: "flex",
              fontSize: 24,
              letterSpacing: 3,
              color: "#08090a",
              background: "#ffb020",
              borderRadius: 999,
              padding: "10px 26px",
            }}
          >
            v{release.version}
          </div>
        </div>

        <Rail />
      </div>
    ),
    size,
  );
}
