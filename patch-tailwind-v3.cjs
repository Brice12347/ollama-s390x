#!/usr/bin/env node
/**
 * patch-tailwind-v3.cjs
 *
 * Applied at Docker build time to make the Open WebUI source (which ships
 * with Tailwind v4 configuration) build correctly with Tailwind v3.
 *
 * Changes made:
 *  1. Rewrites src/tailwind.css  — v4 directives → v3 @tailwind directives
 *     (also inlines the gray-850 custom color as a tailwind.config.js extend)
 *  2. Rewrites postcss.config.js — @tailwindcss/postcss → tailwindcss + autoprefixer
 *  3. Rewrites tailwind.config.js — adds gray-850 to theme.extend.colors
 */

'use strict';

const fs   = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// 1. src/tailwind.css  →  Tailwind v3 directives
//    The v4 file uses: @import 'tailwindcss'; @config …; @theme { … }; @custom-variant …
//    v3 uses: @tailwind base; @tailwind components; @tailwind utilities;
//    We keep the non-Tailwind @layer base rules (fonts, checkbox styles).
// ---------------------------------------------------------------------------
const tailwindCssV3 = `@tailwind base;
@tailwind components;
@tailwind utilities;

@layer base {
\t*,
\t::after,
\t::before {
\t\tborder-color: theme('colors.gray.200');
\t}
}

@layer base {
\thtml,
\tpre {
\t\tfont-family:
\t\t\t-apple-system, BlinkMacSystemFont, 'Inter', 'Vazirmatn', ui-sans-serif, system-ui, 'Segoe UI',
\t\t\tRoboto, Ubuntu, Cantarell, 'Noto Sans', sans-serif, 'Helvetica Neue', Arial,
\t\t\t'Apple Color Emoji', 'Segoe UI Emoji', 'Segoe UI Symbol', 'Noto Color Emoji';
\t}

\tpre {
\t\twhite-space: pre-wrap;
\t}

\tbutton {
\t\t@apply cursor-pointer;
\t}

\tinput::placeholder,
\ttextarea::placeholder {
\t\tcolor: theme('colors.gray.400');
\t}

\tinput[type='checkbox'] {
\t\t@apply appearance-none align-middle bg-white border border-gray-300 rounded transition cursor-pointer focus:ring-2 focus:ring-blue-500 focus:outline-none dark:bg-gray-800 dark:border-gray-600 self-center;
\t\tdisplay: inline-block;
\t\tposition: relative;
\t\twidth: 0.875rem;
\t\theight: 0.875rem;
\t}

\tinput[type='checkbox']:checked {
\t\t@apply bg-blue-600 border-blue-600;
\t}

\tinput[type='checkbox']:after {
\t\tcontent: '';
\t\tdisplay: block;
\t\twidth: 100%;
\t\theight: 100%;
\t\topacity: 0;
\t\ttransition: opacity 0.2s;
\t\tposition: absolute;
\t\ttop: 0;
\t\tleft: 0;
\t\tpointer-events: none;
\t\tbackground: url('data:image/svg+xml;utf8,<svg viewBox="0 0 16 16" fill="none" stroke="white" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg"><path d="M4 8l3 3l5-5"/></svg>')
\t\t\tcenter/80% no-repeat;
\t}

\tinput[type='checkbox']:checked:after {
\t\topacity: 1;
\t}
}
`;

const tailwindCssPath = path.join(__dirname, 'src', 'tailwind.css');
fs.writeFileSync(tailwindCssPath, tailwindCssV3, 'utf8');
console.log('✓ src/tailwind.css rewritten to Tailwind v3 directives');

// ---------------------------------------------------------------------------
// 2. postcss.config.js  →  tailwindcss + autoprefixer (v3 style)
// ---------------------------------------------------------------------------
const postcssCfg = `export default {
\tplugins: {
\t\ttailwindcss: {},
\t\tautoprefixer: {}
\t}
};\n`;

fs.writeFileSync(path.join(__dirname, 'postcss.config.js'), postcssCfg, 'utf8');
console.log('✓ postcss.config.js rewritten for Tailwind v3');

// ---------------------------------------------------------------------------
// 3. tailwind.config.js  →  inject gray-850 into theme.extend.colors
//    Open WebUI uses prose-hr:dark:border-gray-850 which is a custom color
//    not present in Tailwind v3's default palette.
// ---------------------------------------------------------------------------
const twCfgPath = path.join(__dirname, 'tailwind.config.js');
let twCfg = fs.readFileSync(twCfgPath, 'utf8');

// Only patch if gray-850 not already present
if (!twCfg.includes('gray-850') && !twCfg.includes("'850'")) {
\t// Insert colors: { gray: { 850: '...' } } inside theme.extend: { ... }
\ttwCfg = twCfg.replace(
\t\t/theme:\s*\{\s*extend:\s*\{/,
\t\t`theme: {\n\t\textend: {\n\t\t\tcolors: {\n\t\t\t\tgray: {\n\t\t\t\t\t'850': 'oklch(0.27 0 0)'\n\t\t\t\t}\n\t\t\t},`
\t);
\tfs.writeFileSync(twCfgPath, twCfg, 'utf8');
\tconsole.log('✓ tailwind.config.js patched with gray-850 color');
} else {
\tconsole.log('  tailwind.config.js already has gray-850, skipping');
}
