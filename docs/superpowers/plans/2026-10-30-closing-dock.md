# Closing Dock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the homepage's "Get organised today" card and the site footer with a closing
band on the hero's wallpaper. The band holds a Dock (GitHub · What's new · Contact | Studio) and
names Happy Machines Company across the whole site.

**Architecture (the Studio popover is a deliberate copy of the hero's list-popover markup,
like the bento clone, rather than a component lifted out of `DockDemo`; the spec allows either,
and copying keeps the hero untouched; Task 6 records it in the rules):**
- **Reuse the hero's pieces rather than copying them.** Extend the vendored `MacOSDock` with
  optional props that the hero doesn't pass: link items, tooltip nodes, touch labels and a
  divider.
- **One home for the shared geometry and faces.** The popover's anchor maths moves into a pure
  helper in `lib/`, and `TileFace` is exported from `dock-demo.tsx`.
- **The new band composes these.** It lives in its own two files, a band and a Dock with its
  Studio popover.

**Tech Stack:** Next.js 16 App Router, React 19, Tailwind v4, next-themes. No test suite: lint,
tsc, build and scripted visual checks are the tests.

**Spec:** `docs/superpowers/specs/2026-10-30-closing-dock-design.md`. Read it first. Its
"Decisions" items are referenced below as S1–S12.

**Skills while building:** `emil-design-eng` for every visual and motion detail.
`website/CLAUDE.md` and `website/.claude/rules/*` outrank anything here.

## Global Constraints

- Work only in `website/` and `docs/`. Never touch `DockTile/`, `*.swift` or the xcodeproj.
- Copy: every new visible string goes in `marketingBase` in `website/lib/i18n.ts`. Proper nouns
  (product and studio names, URLs) go in `siteConfig` instead.
- Every `/assets/…` reference goes through `asset()`.
- Theming is CSS only (`dark:` / `.dark`), never a mounted-theme guard.
- Animate only transform and opacity, never `transition: all`. Every animation has a
  reduced-motion resting state.
- Headline: `All your apps. One tile.`
- Contact: `hello@happymachines.company`.
- Studio: `Happy Machines Company`, `https://happymachines.company`.
- Lango link: `https://happymachines.company/#products`.
- Referral tag on links to the studio and its apps: `utm_source=docktile.app&utm_medium=referral`.
  It never goes on GitHub, mailto or JSON-LD URLs.
- The hero renders and behaves exactly as before. Every new `MacOSDock` prop is optional and
  defaults to the current behaviour.
- `lib/config.ts`: only `contactEmail`, `authorName`, `authorUrl` and the new `langoUrl` may be
  edited. Don't merge while a release run is in flight (spec, Constraints).
- Commit only when the owner asks. The commit steps below are the points to propose a commit.

## Review Focus

1. **Touch on a 375 px phone.** The labels show, tapping the Studio tile opens a popover that
   isn't clipped, and an outside tap closes it. Covered in Task 7, steps 3 and 4.
2. **Keyboard.** Tab reaches every Dock item, Enter on Studio opens the popover, Escape closes it,
   and the links inside it are reachable. Covered in Task 7, step 5.
3. **Dark theme on first load.** The closing band shows the dark wallpaper and the dark tile faces
   on frame one, with no flash. Covered in Task 7, step 3.
4. **Hero regression after the `MacOSDock` and anchor changes.** Covered in Task 1, step 1
   (baseline) and Task 7, step 6 (re-run).
5. **Screen readers.** No "↗" in any accessible name. External links announce "(opens in a new
   tab)". The Dock container is not a button when its items are links. Covered in Task 7, step 5.

---

### Task 1: Record the hero baseline, then share the popover geometry and tile face

**Files:**
- Create: `website/lib/dock-popover.ts`
- Modify: `website/components/dock-demo.tsx` (the `anchor` callback around lines 233–249, and
  `TileFace` and `ICON_CONTENT_RATIO` around lines 108–145)

**Interfaces:**
- Produces:
  - `anchorPopover(input: { iconRect: DOMRect; rootRect: DOMRect; width: number; viewportWidth: number }): { left: number; arrow: number; bottom: number; width: number }`
  - `export function TileFace(props: { gradient: string; darkGlyph: string; glyph: GlyphName })`
  - `export const ICON_CONTENT_RATIO = "90.625%"`

- [ ] **Step 1: Record the hero baseline.** On an unchanged `main`, run `npm run dev` (port
  3010). In an isolated Chrome profile, plus Playwright WebKit for the touch items:
  - walk the spec's seven-item hero regression checklist;
  - read every hero popover's `getBoundingClientRect()` at 1440 px and 375 px;
  - record both in `.superpowers/sdd/2026-10-30-closing-dock/baseline.md`.
- [ ] **Step 2: Move the anchor maths into `anchorPopover`.**
  - The maths is the current `anchor` body from `const width` to `setPos`.
  - The width cap is `Math.min(width, viewportWidth - 16)`. The 8 px gutters and the 14 px gap
    stay as they are.
  - `DockDemo.anchor` calls `anchorPopover` and keeps its own `null` guards.
- [ ] **Step 3: Export `TileFace` and `ICON_CONTENT_RATIO`.** `TileFace` takes the three plain
  props instead of `DemoTile`, and its call site passes `tile.gradient`, `tile.darkGlyph` and
  `tile.glyph`. Change nothing else in its markup.
- [ ] **Step 4: Verify.** Run `cd website && npm run lint && npx tsc --noEmit`. Expected: both
  clean (lint reports 0 problems). Then reload the hero and click each hero tile: every popover's
  rect matches the step 1 baseline to within 1 px, at both widths.
- [ ] **Step 5: Commit point:** `refactor(website): share dock popover anchor and tile face`.

### Task 2: Add the GitHub and fire glyphs

**Files:**
- Modify: `website/components/tile-glyph.tsx`
- Modify: `website/.claude/rules/hero-dock-demo.md` ("Tile glyphs" section)

**Interfaces:**
- Produces:
  - `GlyphName` gains `"github"` and `"fire"`.
  - `GLYPH_DEFS` entries may now set `fillRule?: "evenodd"` and `stroke?: { width: number }`.

- [ ] **Step 1: Add the `github` entry to `GLYPH_DEFS`.**
  - `viewBox: "0 0 24 24"`, `fillRule: "evenodd"`.
  - The path is the owner-supplied SVG's single `d` attribute, in full:
    `M12.026 2c-5.509 0-9.974 4.465-9.974 9.974 0 4.406 2.857 8.145 6.821 9.465.499.09.679-.217.679-.481 0-.237-.008-.865-.011-1.696-2.775.602-3.361-1.338-3.361-1.338-.452-1.152-1.107-1.459-1.107-1.459-.905-.619.069-.605.069-.605 1.002.07 1.527 1.028 1.527 1.028.89 1.524 2.336 1.084 2.902.829.091-.645.351-1.085.635-1.334-2.214-.251-4.542-1.107-4.542-4.93 0-1.087.389-1.979 1.024-2.675-.101-.253-.446-1.268.099-2.64 0 0 .837-.269 2.742 1.021a9.582 9.582 0 0 1 2.496-.336 9.554 9.554 0 0 1 2.496.336c1.906-1.291 2.742-1.021 2.742-1.021.545 1.372.203 2.387.099 2.64.64.696 1.024 1.587 1.024 2.675 0 3.833-2.33 4.675-4.552 4.922.355.308.675.916.675 1.846 0 1.334-.012 2.41-.012 2.737 0 .267.178.577.687.479C19.146 20.115 22 16.379 22 11.974 22 6.465 17.535 2 12.026 2z`
- [ ] **Step 2: Add the `fire` entry to `GLYPH_DEFS`.**
  - `viewBox: "0 0 24 24"`, `stroke: { width: 1.8 }`.
  - The path is Hugeicons' `FireIcon` (stroke-rounded): `M13.8561 22C26.0783 19 19.2338 7
    10.9227 2C9.9453 5.5 8.47838 6.5 5.54497 10C1.66121 14.6339 3.5895 20 8.96719 22C8.1524 21
    6.04958 18.9008 7.5 16C8 15 9 14 8.5 12C9.47778 12.5 11.5 13 12 15.5C12.8148 14.5 13.6604 12.4
    12.8783 10C19 14.5 16.5 19 13.8561 22Z`.
- [ ] **Step 3: Teach `TileGlyph` the stroke mode.** When `stroke` is set, render `fill="none"
  stroke="currentColor" strokeLinecap="round" strokeLinejoin="round"` with that width. When
  `fillRule` is set, apply `fillRule` and `clipRule`. Existing glyphs render unchanged.
- [ ] **Step 4: Record the exception.** Add one line to the rule and to the file's header comment:
  `fire` is an outline glyph by the owner's choice (2026-10-30), the one exception to "filled
  only".
- [ ] **Step 5: Verify.** Run `npm run lint && npx tsc --noEmit`. Expected: clean.
- [ ] **Step 6: Commit point.**

### Task 3: Extend `MacOSDock` with link items, tooltip nodes, touch labels and a divider

**Files:**
- Modify: `website/components/ui/mac-os-dock.tsx`

**Interfaces:**
- Produces: `DockApp` gains these optional fields. The hero passes none of them.
  - `kind?: "divider"`: a non-interactive separator, not magnified. Its width is
    `Math.max(8, baseIconSize * 0.2)`, drawn as a centred 1 px `bg-white/25` line about 70% of
    the icon height.
  - `href?: string`: renders the item as `<a href>` instead of `div role="button"`. It still calls
    `onAppClick` on click (for analytics), without `preventDefault`. Link items skip the existing
    Enter/Space `onKeyDown` handler (`mac-os-dock.tsx:266-270`), because its `preventDefault`
    would kill native link activation.
  - `external?: boolean`: with `href`, adds `target="_blank" rel="noopener noreferrer"`. Its
    accessible name is `` `${app.name} ${externalHint}` ``, where `externalHint?: string` is a new
    `MacOSDockProps` field carrying the `opensInNewTab` string. It goes in `aria-label` because
    `aria-label` overrides child text, so a hidden child span would never be announced.
  - `tooltip?: React.ReactNode`: replaces `{app.name}` in the tooltip span. `aria-label` stays
    `app.name`.
  - `label?: React.ReactNode`: a caption under the item, shown only under
    `[@media(hover:none)]`. When any item has a label, the inner box adds bottom room under the
    same media query, so labels never overlap the shelf edge.
  - Container: `role="button" tabIndex={0}` is kept only when no item has `href`.

- [ ] **Step 1: Make the layout cumulative.** Rest centres in `calculateTargetMagnification` come
  from cumulative widths (icon or divider, plus `baseSpacing`) instead of
  `index * (baseIconSize + baseSpacing)`. `calculatePositions` uses the divider width with scale
  fixed at 1 for divider items, and divider target scale is always 1.
  - Make the fallback `contentWidth` cumulative too (`mac-os-dock.tsx:223`), so the first frame
    is right when there is a divider.
  - With no dividers all three formulas produce exactly the old numbers. Check it by reasoning:
    the cumulative sum of equal widths equals the index formula.
- [ ] **Step 2: Add the item, tooltip, label and container behaviour** listed under Interfaces.
- [ ] **Step 3: Verify.** Run `npm run lint && npx tsc --noEmit`. Expected: clean. Then reload
  the hero: the Dock magnifies, tooltips show and popovers open, all exactly as in the Task 1
  baseline.
- [ ] **Step 4: Commit point.**

### Task 4: Config, strings, studio assets and the Happy Machines mark

**Files:**
- Modify: `website/lib/config.ts`
  - `contactEmail: "hello@happymachines.company"`
  - `authorName: "Happy Machines Company"`
  - `authorUrl: "https://happymachines.company"`
  - add `langoUrl: "https://happymachines.company/#products"`
  - add `spadesAudioName: "Spades Audio"` and `langoName: "Lango"`
- Create: `website/lib/referral.ts`
- Modify: `website/lib/i18n.ts` (`marketingBase`)
- Create: `website/components/hmc-mark.tsx`
- Create, under `website/public/assets/studio/` (every file 256×256 PNG, normalised):
  - `dock-tile.png`
  - `spades-audio.png` and `spades-audio-dark.png`
  - `lango.png`

**Interfaces:**
- Produces:
  - `withReferral(url: string): string`: sets `utm_source=docktile.app` and
    `utm_medium=referral` through `URL` and keeps any existing hash (the Lango `#products`
    survives).
  - `HmcMark({ className }: { className?: string })`: an inline SVG of the studio mark, using
    `currentColor`.
  - New `marketingBase` keys:
    - `closingTitle: "All your apps. One tile."`
    - `closingGithubTip: "Source on GitHub"`, `closingGithubLabel: "GitHub"`
    - `closingWhatsNewTip: "What's new in"` (the component appends ` {latestVersion}`),
      `closingWhatsNewLabel: "What's new"`
    - `closingContactTip: "Get in touch"`, `closingContactLabel: "Contact"`
    - `closingStudioLabel: "Studio"`
    - `studioHere: "You're here"`, `studioEarlyAccess: "Early access"`
    - `opensInNewTab: "(opens in a new tab)"`

- [ ] **Step 1: Make the config and string edits** listed above. Add no US overrides: none of the
  strings has a spelling variant.
- [ ] **Step 2: Implement `withReferral`.** Check it by running, from `website/`:
  `node --input-type=module -e "import {withReferral} from './lib/referral.ts';
  console.log(withReferral('https://happymachines.company/#products'))"`
  (Node 26 strips the TypeScript types). Expected output:
  `https://happymachines.company/?utm_source=docktile.app&utm_medium=referral#products`.
- [ ] **Step 3: Write `HmcMark`.**
  - viewBox `0 0 86 79`.
  - The path comes from `Spades/spades-audio-landing-page/public/hmc-logo.svg`, with the stroke
    set to `currentColor` and width 5.
  - No clip-path wrapper. Drop the source's `opacity="0.75"`: the call site sets the colour.
- [ ] **Step 4: Add the studio assets**, every one normalised to the site's size-parity law:
  content is 232 px of a 256 px canvas (90.625%), centred, on a transparent background.
  - **Normaliser.** Write `normalise-icon.swift` in the session scratchpad (not committed). It
    takes an input image and an optional `--squircle` flag, which masks to a 22.5% continuous
    rounded rect first. It trims the transparent bounding box, scales the content's larger side to
    232 px, centres it on 256×256 and writes a PNG.
  - **Sources:**
    - `dock-tile.png`: the installed app's `AppIcon.icns`, via `sips -s format png
      --resampleWidth 1024`, then the normaliser.
    - `spades-audio.png` / `spades-audio-dark.png`: `DockTile/Resources/SpadesIconLight.png` /
      `SpadesIconDark.png` (read-only use of app files), then the normaliser.
    - `lango.png`: `https://happymachines.company/products/lango.svg`, rasterised at 1024 with
      `qlmanage -t -s 1024 -o <scratch> lango.svg`, then the normaliser with `--squircle`.
  - **Check:** the normaliser prints each output's opaque bounding box. Expected: 232×232
    (±1 px) centred in 256×256 for every file. Then open each output and look at it.
- [ ] **Step 5: Hand the upload to the owner (outward action).** Ask the owner to upload the four
  files to R2 at `assets/studio/…`. Production 404s until they do. Don't attempt the upload, and
  don't push or merge until the owner confirms it is done.
- [ ] **Step 6: Verify.** Run `npm run lint && npx tsc --noEmit`. Expected: clean.
- [ ] **Step 7: Commit point.**

### Task 5: The closing band and Dock replace `FinalCta`

**Files:**
- Create: `website/components/closing-band.tsx`
- Create: `website/components/closing-dock.tsx`
- Modify: `website/app/page.tsx` (`FinalCta` → `ClosingBand`)
- Modify: `website/components/home-sections.tsx` (delete `FinalCta` and any imports it alone
  used)
- Modify: `website/lib/i18n.ts`: delete `ctaTitle` (base and US), `metaAppleSilicon`,
  `spadesLead` and `spadesButton`, each only after `grep -rn` shows no other user. Keep
  `ctaMetaOpenSource`, `supportText` and `supportLink`.

**Interfaces:**
- Consumes: everything Tasks 1–4 produce.
- Produces: `ClosingBand()` (no props) and `ClosingDock()` (no props).

- [ ] **Step 1: Build `ClosingBand`** (spec S1).
  - Section: `data-nav-tone="dark"`, `relative mx-3 mb-3 rounded-[2.5rem] md:mx-4 md:mb-4`, and
    **no** `overflow-hidden`.
  - Inside it, an `absolute inset-0 overflow-hidden rounded-[inherit] bg-black` layer holds
    (`bg-black` keeps the white text readable until the wallpaper loads, as `hero.tsx:17` does):
    - the `.hero-texture` div, with the same two CSS vars as `hero.tsx`;
    - the scrim, `bg-linear-to-b from-black/10 via-black/55 to-black/95`;
    - `.grain`.
  - Content, wrapped in `Reveal`:
    - the headline, with the hero's radial-masked readability blur div copied from
      `hero.tsx:39-42`, styled `text-3xl md:text-5xl font-bold tracking-[-0.05em]
      leading-[1.05] text-white`;
    - `DownloadActionButton tone="light" size="lg" label={m.ctaButton}`;
    - `ClosingDock`, with enough top margin that the open popover never overlaps the Download
      button. Size the margin from the measured popover height at the hero Dock's size (64–80 px
      icons, 1.8× magnification), not from the mockup's 47 px `mt-24`. Task 7, step 4 asserts it.
- [ ] **Step 2: Build `ClosingDock`** (spec S2–S5).
  - `MacOSDock` items, in order:
    1. GitHub: `TileFace` with gradient `linear-gradient(to bottom, #3d444d, #0d1117)`,
       `darkGlyph: "#ffffff"`, glyph `github`. Links to `siteConfig.githubUrl`, external.
    2. What's new: gradient `linear-gradient(to bottom, #FDBA74, #EA580C)`, `darkGlyph:
       "#FB923C"`, glyph `fire`. Links to `/release-notes`.
    3. Contact: gradient `linear-gradient(to bottom, #4AA8FF, #0A6FE8)`, `darkGlyph: "#4AA8FF"`,
       glyph `chat`. Links to `mailto:` + `contactEmail`. Not external (no new tab), but it still
       shows ↗.
    4. Divider.
    5. Studio: a button that opens the popover.
  - Tooltips use the `*Tip` strings, plus a lucide `ArrowUpRight` (`h-3 w-3`) for GitHub and
    Contact. Labels use the `*Label` strings, with the same arrow on GitHub and Contact.
  - Studio face: a 2×2 grid with fixed cell sizes in px derived from `baseIconSize`, never `%`
    heights. A `%`-height SVG blew the cell up in the mockup.
    - Order: `HmcMark` on a white rounded cell, then `dock-tile.png`, `spades-audio.png` (with
      `spades-audio-dark.png` dual-rendered through `dark:hidden` / `hidden dark:block`), and
      `lango.png`.
    - Light theme: a `from-white to-[#ececee]` plate. Dark theme: `from-[#313133] to-[#141415]`.
  - Clicks:
    - GitHub: `trackExternalLinkClick(url, "closing_dock")`.
    - What's new: `trackReleaseNotesClick()`.
    - Contact: `trackContactClick()`.
    - Studio: toggles the popover.
- [ ] **Step 3: Build the Studio popover** inside `closing-dock.tsx` (spec S3).
  - Position: `anchorPopover` with width 240. **Render the popover after `MacOSDock` in the
    DOM**, so Tab moves from the Studio tile into its links. `DockDemo` renders it before the Dock
    (`dock-demo.tsx:578` vs `:717`), so don't copy that order. When the popover is opened by
    keyboard (Enter or Space), move focus to its first link.
  - Surface: `.popover-surface` with the arrow span, styled like `dock-demo.tsx`.
  - Motion: `dock-scale-in` / `dock-scale-out`, or the reduced-motion `dock-pop-*` fades.
  - Closing: a 200 ms close timer cancelled by a reopen. Outside `pointerdown` and Escape both
    dismiss.
  - Rows:
    - header `siteConfig.authorName`;
    - Dock Tile + `studioHere` (plain text);
    - `siteConfig.spadesAudioName` → `withReferral(siteConfig.spadesAudioUrl)`;
    - `siteConfig.langoName` + `studioEarlyAccess` → `withReferral(siteConfig.langoUrl)`;
    - each app row leads with its 24 px studio icon (the same files as the Studio cells);
    - divider;
    - `happymachines.company` → `withReferral(siteConfig.authorUrl)`.
  - Every external row has ↗ (`aria-hidden`) and visually hidden `opensInNewTab` text. These rows
    are plain `<a>` elements with no `aria-label`, so the hidden text is announced. Each one calls
    `trackExternalLinkClick(url, "studio_popover")`.
- [ ] **Step 4: Swap it in and clean up.** In `page.tsx`, swap `FinalCta` for `ClosingBand`.
  Delete `FinalCta`, then grep and delete the dead keys listed under Files.
- [ ] **Step 5: Verify.** Run `npm run lint && npx tsc --noEmit && npm run build`. Expected: all
  three clean.
- [ ] **Step 6: Commit point.**

### Task 6: Legal line footer, structured data, legal pages and rules

**Files:**
- Modify: `website/components/footer.tsx` (spec S6, S7)
- Modify: `website/lib/schema.ts` (S10)
- Modify: `website/app/privacy/privacy-content.tsx:84-86`, `website/app/terms/terms-content.tsx:31,37`
  (S11)
- Modify: `website/lib/i18n.ts`: delete `footerMessage` from all three locale objects, after a
  grep.
- Modify: `website/.claude/rules/content-i18n.md`, `seo-geo.md`, `hero-dock-demo.md`

- [ ] **Step 1: Rewrite the footer.** Keep the current three-part grid.
  - Left: `© {year} ` and then `siteConfig.authorName`, linking to
    `withReferral(siteConfig.authorUrl)` with `trackExternalLinkClick(…, "footer")`.
  - Centre: `ThemeSwitcher`.
  - Right: Privacy and Terms.
  - The GitHub link and `footerMessage` go.
- [ ] **Step 2: Switch the structured data to the studio.** Replace `person` with
  `organization = { "@type": "Organization", name: siteConfig.authorName, url:
  siteConfig.authorUrl }`, used for `websiteSchema.publisher` and the app's `author` and
  `publisher`. Keep `sameAs: [siteConfig.githubUrl]`. Rewrite the comment: Organization
  publisher, and `sameAs` is what disambiguates from `NSDockTile`.
- [ ] **Step 3: Change who the legal pages name.**
  - Terms: "the developer" → "Happy Machines Company".
  - Privacy lines 84–86: the whole first-person paragraph ("helps me", "shows me", "I'd otherwise
    never hear") speaks for the studio ("we", "us"), so the voice is never mixed.
  - No claim changes meaning. Show the owner the before and after of each sentence.
- [ ] **Step 4: Update the rules.**
  - `content-i18n.md`: the page structure becomes `… → PowerUserSection → ClosingBand`. Drop the
    Spades cross-promo bullet and describe the closing Dock in one line.
  - `seo-geo.md`: Person → Organization. Add the referral-tag rule.
  - `hero-dock-demo.md`: add a "Closing Dock" note covering:
    - the shared `anchorPopover` and `TileFace`;
    - the `MacOSDock` optional props;
    - the fixed-px Studio cells;
    - that the Studio popover's markup is a deliberate copy of the hero's list popover (like the
      bento clone), so it must be kept in sync when the hero's popover changes.
  - `design-system.md`: replace every "Final CTA" reference with the closing band. That covers the
    signature-dark band list, the Ghost card note and "the hero + Final CTA still offer
    Download".
- [ ] **Step 5: Verify.** Run `npm run lint && npx tsc --noEmit && npm run build`. Expected:
  clean. Then `grep -rnE '"Karthik"|https://rkarthik\.co|support\.docktile' website/app
  website/components website/lib` returns nothing. The pattern deliberately leaves out the
  `docktile.rkarthik.co` alias comment in `config.ts` and `rkarthik-zehn` in `assets.ts`.
- [ ] **Step 6: Commit point.**

### Task 7: Visual and behavioural verification

**Files:** none (evidence only, saved under the session scratchpad).

- [ ] **Step 1: Build and serve.** Run `NEXT_PUBLIC_IMAGE_SOURCE=local npm run build && npm run
  start` (port 3010). Without that variable, `asset()` points at R2, where the new studio files
  don't exist yet (`lib/assets.ts:32-35`). Expected: both succeed and the server answers on 3010.
- [ ] **Step 2: Check the structured data.** Run `curl -s localhost:3010 | grep -o
  '"publisher":{[^}]*}'`. Expected: `Organization`, `Happy Machines Company`. Then
  `curl -s localhost:3010 | grep -c '"sameAs":\["https://github.com/k97/dock-tile"\]'` returns 1
  or more.
- [ ] **Step 3: Screenshots.** Use an isolated headless Chrome profile
  (`--user-data-dir=<scratch>`), never the owner's browser, and Playwright WebKit. Capture the
  closing band at 1440 px and 375 px, in light and dark (dark set before load):
  - the dark wallpaper and dark tile faces are right on the first frame;
  - the touch labels show only in the 375 px touch (`hasTouch`) run.
  Headless can't render `backdrop-filter`, so check glass by eye in a real, isolated Chrome.
- [ ] **Step 4: Popover position.** Open the Studio popover at 1440 px and at 375 px, and read
  each box with `getBoundingClientRect`. Expected:
  - the popover sits inside the viewport with an 8 px gutter;
  - it is not clipped by the band;
  - it does not intersect the Download button's rect.
  Also check hover tooltips (desktop) and that the Dock is static under reduced motion (no
  magnification lerp jank, popover fades).
- [ ] **Step 5: Keyboard and screen reader.**
  - Tab through the Dock and press Enter on Studio. Expected: the popover opens, Tab reaches its
    links, and Escape closes it.
  - Accessibility tree: no accessible name contains "↗". External links end with "(opens in a
    new tab)". The Dock container has no `button` role.
- [ ] **Step 6: Hero regression.** Re-run Task 1's seven-item checklist. Expected: identical to
  the baseline.
- [ ] **Step 7: Subpages.** Load `/faq`, `/release-notes`, `/privacy` and `/terms`. Expected:
  `ContactCta` mails `hello@happymachines.company`, the new legal line and the theme switcher
  show, and there is no closing Dock.
- [ ] **Step 8: Gate.** Run `stage-gate --dev` with a fresh reviewer before any push.
