#!/usr/bin/env node
// loopl app mark + icon generator.
//   node scripts/design-icon.mjs            → App/Resources/brand/*.svg + App/Assets.xcassets/AppIcon.appiconset/*.png
// Geometry mirrors Sources/LooplUI/LooplMark.swift (LooplMarkShape): a loop (ouroboros
// stroke) from 28° round to 300° whose head is the tiny flame, flame palette orange→amber.
// Rendering: sharp (librsvg) from ~/.tiny/npm; falls back to rsvg-convert if sharp is missing.
import { writeFileSync, mkdirSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const brand = join(root, "App/Resources/brand");
const iconset = join(root, "App/Assets.xcassets/AppIcon.appiconset");
mkdirSync(brand, { recursive: true });
mkdirSync(iconset, { recursive: true });

const ORANGE = "#FF7A22", AMBER = "#FFC244", INK = "#0E0E11", CREAM = "#FBF5E9";

// ---- geometry (unit square, same numbers as LooplMarkShape) ----
const C = { x: 0.5, y: 0.54 }, R = 0.32, W = 0.115;
const deg = (a) => (a * Math.PI) / 180;
const pt = (a, r = R) => ({ x: C.x + r * Math.cos(deg(a)), y: C.y + r * Math.sin(deg(a)) });
const TAIL = 28, HEAD = 300;

function markPaths(s, { fill = "url(#flame)", pad = 0 } = {}) {
  // scale unit → s px with uniform padding
  const k = s * (1 - 2 * pad), o = s * pad;
  const X = (v) => (o + v * k).toFixed(3);
  const t = pt(TAIL), h = pt(HEAD);
  const loop = `M ${X(t.x)} ${X(t.y)} A ${(R * k).toFixed(3)} ${(R * k).toFixed(3)} 0 1 1 ${X(h.x)} ${X(h.y)}`;
  // flame: teardrop in a unit box, base centred on the head of the loop, leaning 22° into the gap
  const fw = W * 2.2 * k, fh = W * 3.3 * k;
  const fx = o + (h.x - (W * 2.2) / 2) * k, fy = o + (h.y - W * 3.3 * 0.7) * k;
  const cx = fx + fw / 2, cy = fy + fh / 2;
  const flame = [
    "M 0.66 0",
    "C 0.86 0.22 1 0.44 1 0.64",
    "C 1 0.86 0.78 1 0.5 1",
    "C 0.22 1 0 0.86 0 0.64",
    "C 0 0.34 0.42 0.3 0.66 0 Z",
  ].join(" ");
  return `
  <path d="${loop}" fill="none" stroke="${fill}" stroke-width="${(W * k).toFixed(3)}" stroke-linecap="round"/>
  <g transform="rotate(-6 ${cx.toFixed(3)} ${cy.toFixed(3)}) translate(${fx.toFixed(3)} ${fy.toFixed(3)}) scale(${fw.toFixed(3)} ${fh.toFixed(3)})">
    <path d="${flame}" fill="${fill}"/>
  </g>`;
}

const defs = (s) => `
  <defs>
    <linearGradient id="flame" x1="0" y1="${s}" x2="${s}" y2="0" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${ORANGE}"/><stop offset="1" stop-color="${AMBER}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.62" cy="0.3" r="0.75">
      <stop offset="0" stop-color="${ORANGE}" stop-opacity="0.22"/><stop offset="1" stop-color="${ORANGE}" stop-opacity="0"/>
    </radialGradient>
  </defs>`;

function svg(s, body) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 ${s} ${s}">${defs(s)}${body}\n</svg>\n`;
}

const S = 1024;
const files = {
  // the bare mark (transparent) — docs, README, launch assets
  "loopl-mark.svg": svg(S, markPaths(S)),
  // app icon: ink canvas, soft glow, mark with 12% padding (iOS masks the corners itself)
  "loopl-icon.svg": svg(S, `<rect width="${S}" height="${S}" fill="${INK}"/><rect width="${S}" height="${S}" fill="url(#glow)"/>${markPaths(S, { pad: 0.12 })}`),
  // dark appearance (iOS 18): same canvas, slightly deeper glow
  "loopl-icon-dark.svg": svg(S, `<rect width="${S}" height="${S}" fill="#000000"/><rect width="${S}" height="${S}" fill="url(#glow)"/>${markPaths(S, { pad: 0.12 })}`),
  // tinted appearance: iOS tints a grayscale image — white mark on black
  "loopl-icon-tinted.svg": svg(S, `<rect width="${S}" height="${S}" fill="#000000"/>${markPaths(S, { fill: "#FFFFFF", pad: 0.12 })}`),
  // light variant on cream (marketing / docs)
  "loopl-icon-light.svg": svg(S, `<rect width="${S}" height="${S}" rx="${(S * 0.2237).toFixed(0)}" fill="${CREAM}"/>${markPaths(S, { pad: 0.12 })}`),
};
for (const [name, text] of Object.entries(files)) writeFileSync(join(brand, name), text);

async function render(svgPath, pngPath, size = 1024) {
  let sharp;
  try {
    sharp = createRequire(join(homedir(), ".tiny/npm/package.json"))("sharp");
  } catch {}
  if (sharp) {
    await sharp(svgPath, { density: 300 }).resize(size, size).flatten({ background: "#000000" }).removeAlpha().png().toFile(pngPath);
  } else {
    execFileSync("rsvg-convert", ["-w", String(size), "-h", String(size), "-b", "#000000", "-o", pngPath, svgPath]);
  }
}

const outputs = [
  ["loopl-icon.svg", join(iconset, "icon.png")],
  ["loopl-icon-dark.svg", join(iconset, "icon-dark.png")],
  ["loopl-icon-tinted.svg", join(iconset, "icon-tinted.png")],
  ["loopl-icon-light.svg", join(brand, "loopl-icon-light-1024.png")],
  ["loopl-icon.svg", join(brand, "loopl-icon-1024.png")],
];
for (const [src, dst] of outputs) await render(join(brand, src), dst);
// a transparent mark PNG for docs/marketing
{
  let sharp; try { sharp = createRequire(join(homedir(), ".tiny/npm/package.json"))("sharp"); } catch {}
  const src = join(brand, "loopl-mark.svg"), dst = join(brand, "loopl-mark-512.png");
  if (sharp) await sharp(src, { density: 300 }).resize(512, 512).png().toFile(dst);
  else execFileSync("rsvg-convert", ["-w", "512", "-h", "512", "-o", dst, src]);
}

writeFileSync(join(iconset, "Contents.json"), JSON.stringify({
  images: [
    { filename: "icon.png", idiom: "universal", platform: "ios", size: "1024x1024" },
    { appearances: [{ appearance: "luminosity", value: "dark" }], filename: "icon-dark.png", idiom: "universal", platform: "ios", size: "1024x1024" },
    { appearances: [{ appearance: "luminosity", value: "tinted" }], filename: "icon-tinted.png", idiom: "universal", platform: "ios", size: "1024x1024" },
  ],
  info: { author: "xcode", version: 1 },
}, null, 2) + "\n");

console.log("wrote", Object.keys(files).join(", "), "+ AppIcon icon.png / icon-dark.png / icon-tinted.png");
