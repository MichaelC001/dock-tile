// Happy Machines Company mark (from the studio's hmc-logo.svg), drawn in
// currentColor so each call site sets its own tone.
export function HmcMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 86 79" fill="none" className={className} aria-hidden>
      <path
        d="M25 52.275C39.0707 62.0798 46.9454 61.9367 61 52.275M43 3L68.4558 13.6906L79 39.5L68.4558 65.3094L43 76L17.5442 65.3094L7 39.5L17.5442 13.6906L43 3Z"
        stroke="currentColor"
        strokeWidth="5"
      />
    </svg>
  );
}
