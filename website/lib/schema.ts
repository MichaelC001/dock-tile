// JSON-LD structured data (schema.org) for search engines and AI answer
// engines. Every field is wired to siteConfig or the en-AU i18n content —
// the variant SSR renders, i.e. what crawlers actually see. Never hardcode
// values here that already live in config.ts or i18n.ts.
import { siteConfig } from "@/lib/config";
import { localisedContent } from "@/lib/i18n";

const content = localisedContent["en-AU"];

// Dock Tile is made and published by the studio, Happy Machines Company. The
// app's `sameAs` (its GitHub repo) is what disambiguates "Dock Tile" the app
// from Apple's NSDockTile API when AI engines resolve the entity.
const organization = {
  "@type": "Organization",
  name: siteConfig.authorName,
  url: siteConfig.authorUrl,
};

export const websiteSchema = {
  "@context": "https://schema.org",
  "@type": "WebSite",
  name: siteConfig.appName,
  url: siteConfig.siteUrl,
  publisher: organization,
};

export const softwareApplicationSchema = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: siteConfig.appName,
  description: siteConfig.description,
  url: siteConfig.siteUrl,
  applicationCategory: "UtilitiesApplication",
  operatingSystem: "macOS 15.0 or later",
  processorRequirements: "Apple silicon (arm64)",
  softwareVersion: siteConfig.latestVersion,
  downloadUrl: siteConfig.downloadUrl,
  releaseNotes: `${siteConfig.siteUrl}/release-notes`,
  screenshot: `${siteConfig.siteUrl}/assets/stage/dock-tiles.webp`,
  offers: {
    "@type": "Offer",
    price: 0,
    priceCurrency: "USD",
  },
  author: organization,
  publisher: organization,
  sameAs: [siteConfig.githubUrl],
  featureList: [
    ...content.features.map((f) => `${f.title} — ${f.description}`),
    `${content.marketing.ghostTitle} ${content.marketing.ghostBody}`,
    `${content.marketing.smartAddTitle} ${content.marketing.smartAddBody}`,
  ],
};

export const faqPageSchema = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: content.faq.map((item) => ({
    "@type": "Question",
    name: item.question,
    acceptedAnswer: { "@type": "Answer", text: item.answer },
  })),
};
