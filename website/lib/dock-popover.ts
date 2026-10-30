// Where a Dock popover sits: centred over the clicked icon, clamped to an 8px
// viewport gutter, 14px above the icon's top (holds while the icon is
// magnified). Shared by the hero DockDemo and the closing Dock, so both Docks
// anchor identically. Positions are relative to the popover's positioned root.
export function anchorPopover({
  iconRect,
  rootRect,
  width,
  viewportWidth,
}: {
  iconRect: DOMRect;
  rootRect: DOMRect;
  width: number;
  viewportWidth: number;
}): { left: number; arrow: number; bottom: number; width: number } {
  // Product-tier width, capped so the popover keeps its 8px gutters even on
  // viewports narrower than the tier (320px phones).
  const w = Math.min(width, viewportWidth - 16);
  const centre = iconRect.left + iconRect.width / 2 - rootRect.left;
  const minLeft = 8 - rootRect.left;
  const maxLeft = viewportWidth - 8 - w - rootRect.left;
  const left = Math.max(minLeft, Math.min(centre - w / 2, maxLeft));
  const bottom = rootRect.bottom - iconRect.top + 14;
  return { left, arrow: centre - left, bottom, width: w };
}
