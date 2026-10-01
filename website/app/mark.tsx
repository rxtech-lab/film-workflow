/** The film-frame logo mark, drawn in the current text colour with amber sprockets. */
export function Mark() {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
      <rect
        x="1"
        y="1"
        width="16"
        height="16"
        rx="3.5"
        stroke="currentColor"
        strokeWidth="1.4"
        fill="none"
      />
      <rect x="4" y="4.5" width="2" height="2" rx="0.5" fill="#ffb020" />
      <rect x="4" y="11.5" width="2" height="2" rx="0.5" fill="#ffb020" />
      <rect x="12" y="4.5" width="2" height="2" rx="0.5" fill="#ffb020" />
      <rect x="12" y="11.5" width="2" height="2" rx="0.5" fill="#ffb020" />
      <rect x="7.5" y="7.5" width="3" height="3" rx="0.5" fill="currentColor" />
    </svg>
  );
}
