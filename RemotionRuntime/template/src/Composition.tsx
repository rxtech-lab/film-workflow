import { AbsoluteFill } from "remotion";

export const COMPOSITION_FPS = 30;
export const COMPOSITION_DURATION_IN_FRAMES = 150;
export const COMPOSITION_WIDTH = 1920;
export const COMPOSITION_HEIGHT = 1080;

export const MyComposition: React.FC = () => {
  return (
    <AbsoluteFill style={{ backgroundColor: "#000000", justifyContent: "center", alignItems: "center" }}>
      <h1 style={{ color: "white", fontFamily: "Helvetica, Arial, sans-serif" }}>Film Workflow</h1>
    </AbsoluteFill>
  );
};
