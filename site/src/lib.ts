// Prefix a site-relative path with the deploy base (/omadora/).
export function url(path = ''): string {
	const base = import.meta.env.BASE_URL.replace(/\/$/, '');
	const clean = path.replace(/^\//, '');
	return `${base}/${clean}`;
}

export const REPO = 'https://github.com/etmartinkazoo/omadora';

export const SECTIONS = ['Start here', 'Using omadora', 'Running it', 'Reference'] as const;
