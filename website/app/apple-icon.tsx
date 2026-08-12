import { ImageResponse } from "next/og";

export const size = { width: 180, height: 180 };
export const contentType = "image/png";

export default function AppleIcon() {
  const hole = {
    width: 20,
    height: 20,
    borderRadius: 6,
    background: "#08090a",
  } as const;

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: "0 28px",
          background: "#ffb020",
        }}
      >
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            justifyContent: "space-between",
            height: 122,
          }}
        >
          <div style={hole} />
          <div style={hole} />
          <div style={hole} />
        </div>

        <div
          style={{
            width: 56,
            height: 80,
            borderRadius: 8,
            background: "#08090a",
          }}
        />

        <div
          style={{
            display: "flex",
            flexDirection: "column",
            justifyContent: "space-between",
            height: 122,
          }}
        >
          <div style={hole} />
          <div style={hole} />
          <div style={hole} />
        </div>
      </div>
    ),
    size,
  );
}
