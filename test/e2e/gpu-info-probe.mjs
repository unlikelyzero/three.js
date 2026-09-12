// Temporary diagnostic: launch Chrome exactly like test/e2e/puppeteer.js does and
// dump what chrome://gpu and navigator.gpu report, so the driver actually used
// under CI conditions is visible. Usage: node test/e2e/gpu-info-probe.mjs [icd-path]
import puppeteer from 'puppeteer';

const icd = process.argv[ 2 ] || '/usr/share/vulkan/icd.d/lvp_icd.x86_64.json';

const browser = await puppeteer.launch( {
	headless: ( 'CI' in process.env || process.env.VISIBLE ) ? false : 'new',
	env: { ...process.env, VK_DRIVER_FILES: icd },
	args: [ '--hide-scrollbars', '--enable-unsafe-webgpu', '--enable-features=Vulkan', '--disable-vulkan-surface', '--ignore-gpu-blocklist', '--disable-gpu-driver-bug-workarounds', '--disable-gpu-watchdog', '--no-sandbox' ],
	protocolTimeout: 0,
	dumpio: true,
	userDataDir: './.puppeteer_profile',
} );

const page = await browser.newPage();
await page.goto( 'chrome://gpu', { waitUntil: 'load' } );
await new Promise( r => setTimeout( r, 5000 ) );
// chrome://gpu keeps its report inside a shadow root; walk the composed tree
const text = await page.evaluate( () => {
	const parts = [];
	const walk = ( n ) => {
		if ( n.shadowRoot ) walk( n.shadowRoot );
		for ( const c of n.childNodes ) {
			if ( c.nodeType === 3 ) parts.push( c.textContent );
			else walk( c );
		}
	};
	walk( document.body );
	return parts.join( '\n' );
} );
const keep = /WebGPU|Vulkan|GL_RENDERER|GL_VENDOR|GL_VERSION|Driver|driver|SwiftShader|swiftshader|llvmpipe|Dawn|dawn|ANGLE|Vendor Id|Device Id|Gpu compositing|Rasterization|software/i;
console.log( `--- chrome://gpu (${ text.length } chars, filtered) ---` );
for ( const line of text.split( '\n' ) ) { const l = line.trim(); if ( l && keep.test( l ) && l.length < 200 ) console.log( l ); }

await page.goto( 'about:blank' );
const info = await page.evaluate( async () => {
	if ( ! navigator.gpu ) return 'navigator.gpu undefined';
	const t0 = performance.now();
	const a = await navigator.gpu.requestAdapter( { featureLevel: 'compatibility' } );
	const t1 = performance.now();
	if ( ! a ) return `requestAdapter -> null (${ ( t1 - t0 ).toFixed( 0 ) }ms)`;
	const i = a.info;
	return `adapter ${ i.vendor }/${ i.architecture }/${ i.device }/${ i.description } (${ ( t1 - t0 ).toFixed( 0 ) }ms), features=${ [ ...a.features ].length }`;
} );
console.log( '--- navigator.gpu ---' );
console.log( info );
await browser.close();
