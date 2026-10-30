# Closing Dock: how docktile.app ends

Date: 2026-10-30. Status: approved in conversation, pending the plan.
Scope: `website/` only. Never the macOS app.

## Intent

Dock Tile is made by Happy Machines Company, the studio that also makes Spades Audio and Lango.
The site never says so. The site should name the studio the way the Spades Audio site does.

The owner rejected four footer layouts (a signature swap, Spades-style columns, a native card and a
studio sign-off row). In each one the links and text repeated what the nav and the Download card
already said, only to fill space. So the page's ending is redesigned as one piece: the Download
band and the footer together. The rule is that **every destination appears once within the
ending**.

That scope is the owner's decision. The hero's "vX · Open source" row (release notes and GitHub)
and the nav's Privacy link stay where they are, a page away from the ending. The ending repeats
them on purpose: it is where a reader who reached the bottom looks for the code, the news and
the contact.

The homepage now opens on a Dock (the hero demo). It will close on one too. The studio appears as
a Dock Tile tile whose popover lists the studio's apps. The ending explains the product by using
the product.

## Goals

- Name Happy Machines Company on every page, and as the site's author and publisher in the
  structured data.
- The homepage ending says each thing once: download, source, what's new, contact, the studio,
  legal.
- The design reads as Dock Tile's own: wallpaper, Dock, tiles, popover. It must not look like a
  generic footer.

## Non-goals

- The hero, the nav, the feature sections and the subpage bodies do not change, apart from who the legal pages name (item 11).
- The site does not adopt the Spades Audio design system (layout width, type scale, blue accent,
  OLED theme).
- No new pages, routes or locales.

## Anti-goals (a failure even if it works)

- Any link or fact repeated for the sake of filling space.
- A closing Dock that behaves differently from the hero's Dock (a second hand-built Dock that
  drifts).
- The theme switcher disappearing. It is mandated by `website/.claude/rules/design-system.md`.

## Decisions (the owner's, as made)

### Homepage ending: replaces `FinalCta` + `Footer` in `app/page.tsx`

1. **Closing band.** A rounded `2.5rem` section, `data-nav-tone="dark"`, on the hero's dithered
   wallpaper. Reuse the hero's CSS-var light/dark swap (`.hero-texture` pattern), with a scrim
   that darkens towards the bottom and the 15% grain. It stays dark in both themes, like a
   signature band.
   - Readability (my call): the light wallpaper is brightest at the top, where the headline sits.
     Give the headline the hero's own radial-masked readability blur rather than a stronger
     scrim, the same treatment the hero gives its headline.
   - **The band must not clip the popover.** `FinalCta` uses `overflow-hidden` on the rounded
     section. Clip only the wallpaper, scrim and grain layers to the radius, so a popover opened
     near the band's edge is never cut off.

   It contains:
   - Headline: **"All your apps. One tile."** This is a new i18n key, and it is
     spelling-neutral, so it needs no US override. It replaces `ctaTitle` ("Get organised
     today.").
   - The existing `DownloadActionButton` (`tone="light"`, `size="lg"`), unchanged.
   - Removed:
     - the meta row "Open source · vX · macOS 15+ · Apple silicon" (the hero eyebrow already
       says the requirements);
     - the "Have a question or found a bug? Get in touch" line;
     - the "Also available: Spades Audio" pill.
2. **Closing Dock** under the button. It reuses the hero's `MacOSDock` (`components/ui/mac-os-dock.tsx`):
   magnification is on, the hero's auto-demo cursor is not used, and it starts with the popover
   closed. **Size and magnification follow the hero's `MacOSDock` config**, not the mockup's
   47 px tiles and CSS lift: the mockup sets only the composition. The items, in order:

   | Item | Face | Tooltip | Destination |
   |---|---|---|---|
   | GitHub | `.tile-face` squircle, near-black gradient `#3d444d → #0d1117`, white GitHub mark (the owner supplied the SVG, see Assets); `--tile-glyph-dark: #ffffff` so the mark stays white on the dark-theme tile | Source on GitHub ↗ | `siteConfig.githubUrl` |
   | What's new | `.tile-face`, orange gradient, the Hugeicons `fire` icon in stroke-rounded style | What's new in {version} | `/release-notes` |
   | Contact | `.tile-face`, blue gradient, the existing `chat` glyph from `tile-glyph.tsx` | Get in touch ↗ | `mailto:` + `siteConfig.contactEmail` |
   | (divider) | | | |
   | Studio | App Grid face, 2×2: Happy Machines mark (white tile) · Dock Tile · Spades Audio · Lango | Happy Machines Company | opens the popover |

   - Dark theme: the tiles follow the shared `.tile-face` rule. The background turns
     near-black and the tint moves to the glyph through `--tile-glyph-dark`.
   - The fire icon is an **outline** glyph. That breaks the "filled glyphs only" rule in
     `hero-dock-demo.md`, by the owner's explicit choice. Note the exception in that rule.
   - The Studio face follows the app's App Grid rule (one to four items make a 2×2). Each cell has
     a fixed size: a percentage-sized SVG in an auto-height cell blew the cell up in the mockup.
3. **Studio popover.** It uses the list layout and the same surface, anchoring, arrow, animation
   and dismiss behaviour as the hero's popovers. Rows:
   - Header: "Happy Machines Company"
   - Dock Tile, with a trailing "You're here" (no link)
   - Spades Audio ↗ (`siteConfig.spadesAudioUrl`)
   - Lango, with a trailing "Early access ↗" (`https://happymachines.company/#products`: Lango
     has no site of its own)
   - divider
   - happymachines.company ↗
4. **External links show ↗**: GitHub, Contact and every popover row that leaves the site. It
   appears in the hover tooltip and in the touch label. "What's new" and "Studio" have no ↗.
   - The ↗ is an icon, not a character in the string, so it never reaches `aria-label`. Each
     external link carries a visually hidden "(opens in a new tab)" instead. The mailto link
     carries none.
5. **Touch devices** (`@media (hover: none)`): each Dock item shows a permanent 11px label under
   it ("GitHub ↗", "What's new", "Contact ↗", "Studio"). Hover tooltips and lift stay mouse-only.
6. **Legal line** below the band, on the page background: "© {year} Happy Machines Company" (the
   name links to `https://happymachines.company`) · Privacy · Terms, plus `ThemeSwitcher`. This
   is the new shared `Footer`.

### Site-wide

7. **Shared `Footer`** (`components/footer.tsx`) becomes the legal line from item 6 on every page.
   The old contents go: "© Karthik", "Designed & made with care for macOS" and the GitHub link.
8. **Subpages** (FAQ, Release notes, Privacy, Terms) keep their `ContactCta` band unchanged. The
   new legal line sits below it. The closing Dock is homepage-only, so GitHub is linked only from
   the homepage, which the owner accepted.
9. **Contact address** becomes `hello@happymachines.company` (`siteConfig.contactEmail`). That
   changes `ContactCta`'s button too, which is intended. It now matches the app's About → Send
   Feedback, which `AboutLinksTests` pins.
10. **Structured data** (`lib/schema.ts`): author and publisher become an `Organization`, "Happy
    Machines Company", `https://happymachines.company`. The `Person` entry is removed.
    `SoftwareApplication.sameAs: [githubUrl]` stays: it keeps the `NSDockTile` disambiguation,
    and the comment and `seo-geo.md` must be updated to say so. `app/layout.tsx` has no
    `authors` metadata (checked). The only other users of `authorName` and `authorUrl` are the
    old footer and `schema.ts`, so replace both fields with the studio's name and URL rather than
    keeping a second copy.
11. **The legal pages name the studio** (the owner's decision).
    - Privacy and Terms mail `hello@happymachines.company`. This follows from item 9, because
      both read `siteConfig.contactEmail` (`privacy-content.tsx:145`, `terms-content.tsx:61`).
    - Their wording names Happy Machines Company where it now says "the developer"
      (`terms-content.tsx:31, 37`) or speaks as one person ("As a single developer, this is what
      helps me", `privacy-content.tsx:84`).
    - Change only who is named. Keep every claim (what is collected, the opt-out, the warranty
      disclaimer) word for word in meaning.
    - Follow the pages' existing copy home (the i18n file, or the content file if that is where
      the legal copy already lives).
12. **The hero headline does not change.** "Group your apps. / Declutter your Dock." opens the
    page, and "All your apps. One tile." closes it.

## Constraints (from the repo rules)

- All visible copy goes through `lib/i18n.ts` (en-AU base, plus a US override only where the
  spelling differs). The tooltips, touch labels, popover rows, "You're here", "Early access" and
  the legal line are all strings.
- `lib/config.ts`: CI edits only `downloadUrl`, `releaseNotesUrl` and `latestVersion`
  (`release.yml` lines 452–454). But it then copies the **whole** tag-time file over the latest
  `main` (`release.yml` lines 474 and 480). So hand-editing `contactEmail` and the author fields
  is safe, as long as the change does not merge while a release run is in flight, or the release
  silently reverts it.
- Every `/assets/…` path goes through `asset()`. New files must be uploaded to R2 at the matching
  key, or production returns 404s.
- Theming is CSS-only (`dark:` / `.dark`), never a mounted-theme guard. Animate only transform and
  opacity, never `transition: all`, and give everything a reduced-motion resting state.
- Check layout in WebKit as well as Chromium, because a shrink-to-fit box that contains `<img>` is
  a known WebKit trap.
- Must keep working: the hero Dock's showcase and touch-resume model, the anchored popover, the
  PopoverShowcase bento clone, and the adaptive nav tone.

## What's left to the builder

- **How to reuse the Dock and popover (the main open engineering call).** `MacOSDock` items are
  `role="button"` divs with `onClick`, the tooltip is the plain `name` string, and there is no
  label slot. The outer container is itself `role="button" tabIndex={0}` (`mac-os-dock.tsx:233-234`),
  so links nested inside it would be invalid ARIA. The popover markup and its anchoring live
  inside `DockDemo` (`dock-demo.tsx`), not in a shared component. The builder decides:
  - how to extend the vendored `MacOSDock`, keeping each change small, optional and off by
    default so the hero renders exactly as before. Needed:
    - a tooltip node that can show the ↗ icon;
    - a touch-label slot, with room under the items (the items sit absolutely in a
      `baseIconSize`-high box);
    - a divider item;
    - a link mode, where items are real `<a href>`s (so crawlers and assistive technology can
      see GitHub, release notes and email) and the container drops its own `role="button"`;
  - whether to lift the popover and its anchoring out of `DockDemo` into a shared component both
    Docks use (preferred: one source of truth) or reach the same result another way. The hero's
    behaviour must not change.
- Assets:
  - Studio cells and popover rows use **squircle app icons**, normalised to the size-parity law.
    Don't use `dock-tile-icon-only.svg` (the bare logo glyph) or `spades-audio-icon.svg` (a
    circle), which the mockup used as stand-ins.
    - Dock Tile: the real app icon (`public/assets/dock-tile-icon-1024.png` if it is the full
      icon, otherwise export it from the app's `AppIcon`).
    - Spades Audio: `SpadesIconLight.png` / `SpadesIconDark.png` from the Spades Audio app repo,
      both themes, swapped in CSS.
  - Add the Happy Machines mark (`hmc-logo.svg`, copy it from the Spades site's `public/`) and the
    Lango icon (`https://happymachines.company/products/lango.svg`) under `public/assets/`,
    normalised to the size-parity law (~90.6% content).
  - Add the owner-supplied GitHub mark as a glyph.
  - Add the Hugeicons fire path as a glyph in `tile-glyph.tsx`, where the outline exception is
    noted.
  - Upload every new file to R2.
- Spacing, Dock size and tile gradients: follow the mockup
  (https://claude.ai/artifact/Xth54hQdxnLXzDRAxBmJEL, D1) and the hero's tokens.
- Remove what becomes dead: `FinalCta`, and the `ctaTitle`, `metaAppleSilicon`, `spadesLead`,
  `spadesButton` and `footerMessage` keys, if a grep finds no other user. Keep these:
  - `ctaMetaOpenSource`: the hero still uses it (`hero.tsx:99`).
  - `supportText` and `supportLink`: the dead but still-compiled `support.tsx` references them.
    Deleting that file is out of scope.
- Strings: new copy goes in `marketingBase` (`i18n.ts:20`), which every locale inherits. A US
  override is added only where the spelling differs, and none of the new strings should need one.
  Top-level keys are full copies in each of the three locale objects, so avoid adding any there.
  "What's new in {version}" is assembled in the component from `siteConfig.latestVersion`.
- Update `content-i18n.md` (page structure: `FinalCta` → the closing band; the Spades cross-promo
  line), `hero-dock-demo.md` (the closing Dock, the outline exception) and `design-system.md` if
  a new primitive appears.
  Also update `seo-geo.md`: Person → Organization, and the website's own UTM convention.

### Calls I made (the owner can override)

- Outbound links to the studio and its apps carry `utm_source=docktile.app&utm_medium=referral`,
  matching how happymachines.company tags its links. That includes the legal line's studio link.
  GitHub and mailto links get no UTM.
- Analytics reuse the existing helpers: `trackExternalLinkClick(url, "closing_dock")`,
  `trackReleaseNotesClick`, `trackContactClick`. No new event names.
- The Studio tile's tooltip is the full name and its touch label is "Studio".

## Verification

- `npm run lint`, `npx tsc --noEmit`, `npm run build` (in `website/`).
- Visual check on the dev server (port 3010) in an isolated Chrome profile and in Playwright
  WebKit:
  - light and dark themes, desktop and a 375 px phone;
  - hover tooltips, touch labels, and the popover opening, anchoring and dismissing;
  - reduced motion.
- Hero regression checklist. Run it on `main` before the change, then again after it, and record
  each result:
  1. The showcase starts on its own, the cursor glides, and a popover opens.
  2. A pointer entering hard-stops the showcase, and it resumes about 2.8 s after the pointer
     leaves.
  3. On touch, a popover opened by a tap survives the tap-up, and the showcase re-arms after an
     outside-tap dismiss.
  4. Escape and an outside click both dismiss the popover.
  5. The gear and "Configure…" scroll to `#features`.
  6. The PopoverShowcase bento clone still matches the hero's popovers.
  7. Under reduced motion there is no showcase, and popovers fade.
- Closing popover at 375 px wide, opened from the rightmost tile: no part of it is clipped by the
  band.
- Structured data: the homepage `SoftwareApplication` and the root `WebSite` show the
  Organization, with `sameAs` intact.
- Every page shows the new legal line and the theme switcher. `ContactCta` mails
  `hello@happymachines.company`.
