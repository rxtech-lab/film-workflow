import { Composition } from "remotion";
import { MyComposition, COMPOSITION_FPS, COMPOSITION_DURATION_IN_FRAMES, COMPOSITION_WIDTH, COMPOSITION_HEIGHT } from "./Composition";

export const RemotionRoot: React.FC = () => {
  return (
    <Composition
      id="Main"
      component={MyComposition}
      durationInFrames={COMPOSITION_DURATION_IN_FRAMES}
      fps={COMPOSITION_FPS}
      width={COMPOSITION_WIDTH}
      height={COMPOSITION_HEIGHT}
    />
  );
};
