#!/usr/bin/env node
/**
 * patch-tailwind-v3.cjs
 *
 * Applied at Docker build time to make the Open WebUI source (which ships
 * with Tailwind v4 configuration) build correctly with Tailwind v3.
 *
 * Changes made:
 *  1. Rewrites src/tailwind.css  — v4 directives -> v3 @tailwind directives
 *  2. Rewrites postcss.config.js — @tailwindcss/postcss -> tailwindcss + autoprefixer
 *  3. Rewrites tailwind.config.js — adds gray-850 to theme.extend.colors
 */

'use strict';

const fs   = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// 1. src/tailwind.css  ->  Tailwind v3 directives
// ---------------------------------------------------------------------------
const tailwindCssLines = [
  '@tailwind base;',
  '@tailwind components;',
  '@tailwind utilities;',
  '',
  '@layer base {',
  '  *,',
  '  ::after,',
  '  ::before {',
  "    border-color: theme('colors.gray.200');",
  '  }',
  '}',
  '',
  '@layer base {',
  '  html,',
  '  pre {',
  '    font-family:',
  "      -apple-system, BlinkMacSystemFont, 'Inter', 'Vazirmatn', ui-sans-serif, system-ui, 'Segoe UI',",
  "      Roboto, Ubuntu, Cantarell, 'Noto Sans', sans-serif, 'Helvetica Neue', Arial,",
  "      'Apple Color Emoji', 'Segoe UI Emoji', 'Segoe UI Symbol', 'Noto Color Emoji';",
  '  }',
  '',
  '  pre {',
  '    white-space: pre-wrap;',
  '  }',
  '',
  '  button {',
  '    @apply cursor-pointer;',
  '  }',
  '',
  '  input::placeholder,',
  '  textarea::placeholder {',
  "    color: theme('colors.gray.400');",
  '  }',
  '',
  "  input[type='checkbox'] {",
  '    @apply appearance-none align-middle bg-white border border-gray-300 rounded transition cursor-pointer focus:ring-2 focus:ring-blue-500 focus:outline-none dark:bg-gray-800 dark:border-gray-600 self-center;',
  '    display: inline-block;',
  '    position: relative;',
  '    width: 0.875rem;',
  '    height: 0.875rem;',
  '  }',
  '',
  "  input[type='checkbox']:checked {",
  '    @apply bg-blue-600 border-blue-600;',
  '  }',
  '',
  "  input[type='checkbox']:after {",
  "    content: '';",
  '    display: block;',
  '    width: 100%;',
  '    height: 100%;',
  '    opacity: 0;',
  '    transition: opacity 0.2s;',
  '    position: absolute;',
  '    top: 0;',
  '    left: 0;',
  '    pointer-events: none;',
  "    background: url('data:image/svg+xml;utf8,<svg viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"white\" stroke-width=\"3\" stroke-linecap=\"round\" stroke-linejoin=\"round\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M4 8l3 3l5-5\"/></svg>')",
  '      center/80% no-repeat;',
  '  }',
  '',
  "  input[type='checkbox']:checked:after {",
  '    opacity: 1;',
  '  }',
  '}',
  '',
];

const tailwindCssPath = path.join(__dirname, 'src', 'tailwind.css');
fs.writeFileSync(tailwindCssPath, tailwindCssLines.join('\n'), 'utf8');
console.log('✓ src/tailwind.css rewritten to Tailwind v3 directives');

// ---------------------------------------------------------------------------
// 2. postcss.config.js  ->  tailwindcss + autoprefixer (v3 style)
// ---------------------------------------------------------------------------
const postcssCfg = [
  'export default {',
  '  plugins: {',
  '    tailwindcss: {},',
  '    autoprefixer: {}',
  '  }',
  '};',
  '',
].join('\n');

fs.writeFileSync(path.join(__dirname, 'postcss.config.js'), postcssCfg, 'utf8');
console.log('✓ postcss.config.js rewritten for Tailwind v3');

// ---------------------------------------------------------------------------
// 3. tailwind.config.js  ->  inject gray-850 into theme.extend.colors
// ---------------------------------------------------------------------------
const twCfgPath = path.join(__dirname, 'tailwind.config.js');
let twCfg = fs.readFileSync(twCfgPath, 'utf8');

if (!twCfg.includes('gray-850') && !twCfg.includes("'850'")) {
  const insert = [
    'theme: {',
    '    extend: {',
    '      colors: {',
    '        gray: {',
    "          '850': ({ opacityValue }) =>",
    '            opacityValue !== undefined',
    "              ? 'rgba(26,32,44,' + opacityValue + ')'",
    "              : 'rgb(26,32,44)'",
    '        },',
    '      },',
  ].join('\n');
  twCfg = twCfg.replace(/theme:\s*\{\s*extend:\s*\{/, insert);
  fs.writeFileSync(twCfgPath, twCfg, 'utf8');
  console.log('✓ tailwind.config.js patched with gray-850 color');
} else {
  console.log('  tailwind.config.js already has gray-850, skipping');
}
