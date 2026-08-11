export default {
  plugins: {
    // Must run first so the split stylesheets are inlined before Tailwind.
    'postcss-import': {},
    tailwindcss: {},
    autoprefixer: {},
  },
}
