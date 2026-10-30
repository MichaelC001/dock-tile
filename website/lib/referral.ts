// Tags a link to the studio or one of its apps so their analytics can tell
// Dock Tile sent the visit — the same convention happymachines.company uses
// for its own outbound links. Never applied to GitHub, mailto or JSON-LD URLs.
export function withReferral(url: string): string {
  const u = new URL(url);
  u.searchParams.set("utm_source", "docktile.app");
  u.searchParams.set("utm_medium", "referral");
  return u.toString();
}
