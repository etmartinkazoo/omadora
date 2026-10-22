// @ts-check
import { defineConfig } from 'astro/config';

// Served from GitHub Pages at https://etmartinkazoo.github.io/omadora/
export default defineConfig({
	site: 'https://etmartinkazoo.github.io',
	base: '/omadora',
	trailingSlash: 'always',
	markdown: {
		shikiConfig: { theme: 'github-dark-default', wrap: true },
	},
});
