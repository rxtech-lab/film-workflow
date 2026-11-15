export const GEMINI_SPEECH_MODEL = "gemini-3.8-flash-tts";

type Speaker = { name: string; voice: string };
type Turn = { text: string; speaker: string; style: string };

/** Adapt the desktop's existing labeled transcript to 3.8's verbatim turns. */
export function geminiSpeechRequest(transcript: string, speakers: Speaker[]) {
  const turns: Turn[] = [];
  const directions: string[] = [];
  const legacy = transcript.startsWith("Synthesize speech for the following ");
  for (const line of transcript.split("\n")) {
    const trimmed = line.trim();
    const speaker = speakers.find((item) => trimmed.startsWith(`${item.name}:`));
    if (speaker) {
      let text = trimmed.slice(speaker.name.length + 1).trimStart();
      const emotion = text.match(/^\[([^\]]+)\]\s*/);
      if (emotion) text = text.slice(emotion[0].length);
      turns.push({ text, speaker: speaker.name, style: emotion?.[1] ?? "" });
    } else if (legacy && turns.length === 0) {
      if (trimmed && !trimmed.startsWith("Synthesize speech for the following ")) directions.push(line);
    } else if (turns.length) {
      turns[turns.length - 1].text += `\n${line}`;
    } else if (trimmed) {
      turns.push({ text: line, speaker: speakers[0].name, style: "" });
    }
  }
  if (!turns.length) throw new Error("INVALID_SPEECH_TRANSCRIPT");
  return {
    model: GEMINI_SPEECH_MODEL,
    input: [{ type: "user_input", content: turns.map((turn) => ({
      type: "text", text: turn.text,
      annotations: [{ type: "speech_metadata", speaker: turn.speaker, style: [...directions, turn.style].filter(Boolean).join("\n") }],
    })) }],
    // Keep the route's duration measurement and single WAV wrapper correct.
    response_format: { type: "audio", mime_type: "audio/l16", sample_rate: 24000 },
    generation_config: { speech_config: speakers.length === 1
      ? [{ voice: speakers[0].voice }]
      : { speakers: speakers.map((item) => ({ speaker: item.name, voice: item.voice })) } },
  };
}

export function geminiSpeechAudio(body: unknown): Buffer | null {
  if (!body || typeof body !== "object") return null;
  const steps = (body as { steps?: Array<{ type?: string; content?: Array<{ type?: string; data?: string }> }> }).steps;
  const chunks = (steps ?? []).filter((step) => step.type === "model_output")
    .flatMap((step) => step.content ?? [])
    .filter((part) => part.type === "audio" && typeof part.data === "string" && part.data.length > 0)
    .map((part) => Buffer.from(part.data!, "base64"));
  const audio = Buffer.concat(chunks);
  return audio.length ? audio : null;
}
