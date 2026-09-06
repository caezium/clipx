// Run with Node and Playwright installed. All requests are fulfilled from
// synthetic fixtures; this never contacts a running Clipx app or user library.
// Optional: CLIPX_PLAYWRIGHT_MODULE, CLIPX_BROWSER_EXECUTABLE, CLIPX_FFMPEG.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.CLIPX_PLAYWRIGHT_MODULE || 'playwright');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dir = mkdtempSync(join(tmpdir(), 'clipx-browser-regression-'));
writeFileSync(join(dir, 'assets.swift'), `import Foundation
@main struct Main {
static func main() throws {
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try WebContent.appJS.write(to: dir.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
try WebContent.appCSS.write(to: dir.appendingPathComponent("app.css"), atomically: true, encoding: .utf8)
try WebContent.indexHTML.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
}
}`);
execFileSync('xcrun', ['swiftc', '-module-cache-path', join(dir, 'module-cache'), join(root, 'Sources/ClipxServer/WebContent.swift'), join(dir, 'assets.swift'), '-o', join(dir, 'assets')]);
execFileSync(join(dir, 'assets'), [dir]);
execFileSync(process.env.CLIPX_FFMPEG || 'ffmpeg', ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=0x31475c:s=640x360:r=30:d=6', '-an', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', join(dir, 'video.mp4')]);
const video = readFileSync(join(dir, 'video.mp4'));
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==', 'base64');
const source = id => ({ id, name: `Source ${id}.mov`, hash: String(id).padStart(8,'0'), durationMs: 6000, width: 640, height: 360, fps: 30, online: true, importedAt: 1700000000 - id, createdAt: null, speed: id === 1 ? 2 : 1, rotation: 0 });
const clip = id => ({ id, sourceID: 1, sourceName: 'Source 1.mov', sourceHash: '00000001', name: `Clip ${id}`, inMs: 0, outMs: 2000, durationMs: 2000, rating: 0, createdAt: 0 });
const sources = Array.from({length: 650}, (_,i) => source(i+1));
const clips = Array.from({length: 360}, (_,i) => clip(i+1));
let proxyMode = 'ready', spriteRequests = 0, polls = 0, saved = [];
const errors = [];
const browser = await chromium.launch({ headless: true, executablePath: process.env.CLIPX_BROWSER_EXECUTABLE || undefined });
try {
  const page = await browser.newPage({ viewport: { width: 375, height: 812 } });
  page.on('pageerror', e => errors.push(e.message));
  await page.addInitScript(() => {
    localStorage.setItem('clipxToken', 'synthetic-token');
    window.revokedBlobURLs = [];
    const revoke = URL.revokeObjectURL.bind(URL);
    URL.revokeObjectURL = url => { window.revokedBlobURLs.push(url); revoke(url); };
  });
  await page.route('**/*', async route => {
    const url = new URL(route.request().url()), path = url.pathname;
    const json = body => route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(body)}).catch(()=>{});
    if (path === '/') return route.fulfill({contentType:'text/html',body:readFileSync(join(dir,'index.html'))});
    if (path === '/app.css' || path === '/app.js') return route.fulfill({contentType: path.endsWith('.js') ? 'application/javascript' : 'text/css',body:readFileSync(join(dir,path.slice(1)))});
    if (path.startsWith('/api/thumb/')) return route.fulfill({contentType:'image/png',body:png});
    if (path.startsWith('/api/sprite/')) {
      if (path.includes('abcdef')) spriteRequests++;
      return route.fulfill(path.includes('abcdef') && spriteRequests === 1 ? {status:404,body:'offline'} : {status:200,contentType:'image/png',body:png});
    }
    if (path === '/api/sources' || path === '/api/clips') {
      const offset = Number(url.searchParams.get('offset') || 0), limit = Number(url.searchParams.get('limit') || 100);
      return json((path.endsWith('sources') ? sources : clips).slice(offset,offset+limit));
    }
    if (path === '/api/search') {
      const q = url.searchParams.get('q');
      await new Promise(r => setTimeout(r,q === 'old' ? 650 : 30));
      return json({sources:[{...source(1),name:q+' result.mov'}],clips:[]});
    }
    if (path.endsWith('/proxy-retry')) { proxyMode = 'ready'; return json({ready:true,progress:100,state:'ready'}); }
    if (path.endsWith('/proxy-status')) {
      polls++;
      return json(proxyMode === 'ready' ? {ready:true,progress:100,state:'ready'} : proxyMode === 'failed' ? {ready:false,state:'failed',error:'Synthetic preparation failure'} : {ready:false,state:'queued',progress:0});
    }
    if (path.endsWith('/video')) return route.fulfill({contentType:'video/mp4',body:video,headers:{'Accept-Ranges':'bytes'}});
    if (/\/api\/sources\/\d+$/.test(path)) return json(source(Number(path.split('/')[3])));
    if (/\/api\/sources\/\d+\/clips$/.test(path)) {
      const id = Number(path.split('/')[3]);
      if (route.request().method() === 'POST') {
        saved.push({sourceID:id,...route.request().postDataJSON()});
        await new Promise(r=>setTimeout(r,500)); return json({id:999,ok:true});
      }
      await new Promise(r=>setTimeout(r,id === 1 ? 450 : 20));
      return json([{...clip(id),name:`Clips from source ${id}`}]);
    }
    return route.fulfill({status:404,body:'fixture route not found'});
  });
  await page.goto('http://clipx-fixture.local/');
  await page.waitForFunction(() => document.querySelector('#sources-status').textContent.startsWith('100 sources'));
  for (let i=0;i<6;i++) {
    await page.click('#sources-more');
    await page.waitForFunction(() => !document.querySelector('#sources-more').disabled);
  }
  assert.match(await page.textContent('#sources-status'), /^650 sources$/);
  assert.equal(await page.locator('#sources-calendar .card').count(),650);
  await page.click('.tab[data-tab="clips"]');
  await page.waitForFunction(() => document.querySelector('#clips-status').textContent.startsWith('100 clips'));
  await page.fill('#search','old'); await page.waitForTimeout(280);
  await page.fill('#search','new'); await page.waitForTimeout(800);
  assert.match(await page.textContent('#search-sources-grid'), /new result/);
  assert.doesNotMatch(await page.textContent('#search-sources-grid'), /old result/);
  await page.fill('#search','');
  assert.equal(await page.locator('#clips-pane').evaluate(el=>el.classList.contains('active')),true);
  for (let i=0;i<3;i++) { await page.click('#clips-more'); await page.waitForFunction(()=>!document.querySelector('#clips-more').disabled); }
  assert.match(await page.textContent('#clips-status'),/^360 clips$/);
  await page.locator('#clips-grid .clip-preview').first().click();
  await page.waitForFunction(()=>document.querySelector('#player-modal').open && !document.querySelector('#btn-mark-in').disabled);
  assert.match(await page.textContent('#player-title'), /Source 1/);
  await page.click('#player-close');
  await page.evaluate(([a,b]) => { openSourceDetail(a); openSourceDetail(b); },[source(1),source(2)]);
  await page.waitForTimeout(550);
  assert.match(await page.textContent('#source-clips-grid'),/Clips from source 2/);
  assert.doesNotMatch(await page.textContent('#source-clips-grid'),/Clips from source 1/);
  proxyMode='failed';
  await page.click('#open-player');
  await page.waitForSelector('#player-retry:visible');
  assert.equal(await page.locator('#player-close').evaluate(el=>{
    const r=el.getBoundingClientRect(); return document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)===el;
  }),true,'Close must be reachable above the failure overlay');
  await page.screenshot({path:join(dir,'phone-proxy-error.png')});
  await page.click('#player-close');
  assert.equal(await page.locator('#player-modal').evaluate(el=>el.open),false);
  proxyMode='queued';
  await page.click('#open-player'); await page.waitForTimeout(80); await page.click('#player-close');
  const pollCount = polls; await page.waitForTimeout(2150); assert.equal(polls,pollCount,'Closing must stop polling');
  proxyMode='ready';
  await page.evaluate(s=>openPlayer(s),source(1));
  await page.waitForFunction(()=>document.querySelector('#player-modal').open && !document.querySelector('#btn-mark-in').disabled);
  assert.equal(await page.locator('#player-video').evaluate(v=>v.playbackRate),2);
  await page.locator('#player-video').evaluate(v=>{v.pause();v.currentTime=1;}); await page.click('#btn-mark-in');
  await page.locator('#player-video').evaluate(v=>{v.currentTime=3;}); await page.click('#btn-mark-out');
  await page.click('#btn-save'); await page.click('#player-close');
  await page.evaluate(s=>openPlayer(s),source(2));
  await page.waitForFunction(()=>document.querySelector('#player-modal').open && !document.querySelector('#btn-mark-in').disabled);
  await page.locator('#player-video').evaluate(v=>{v.pause();v.currentTime=2;}); await page.click('#btn-mark-in');
  await page.locator('#player-video').evaluate(v=>{v.currentTime=4;}); await page.click('#btn-mark-out');
  await page.waitForTimeout(650);
  assert.match(await page.textContent('#player-marks'), /In 00:02.00 → Out 00:04.00/);
  assert.deepEqual(saved[0],{sourceID:1,inMs:1000,outMs:3000},'Marks must stay original source ms at 2× playback');
  await page.click('#player-close');
  const spriteResult = await page.evaluate(async()=>{
    const first=await loadSprite('abcdef'); const second=await loadSprite('abcdef'); clearSprites();
    return {first,second,revoked:window.revokedBlobURLs};
  });
  assert.equal(spriteResult.first,null); assert.match(spriteResult.second,/^blob:/); assert.ok(spriteResult.revoked.includes(spriteResult.second));
  for (const width of [320,375,768,1280]) {
    await page.setViewportSize({width,height:812});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth <= innerWidth),true,`No horizontal overflow at ${width}px`);
  }
  await page.setViewportSize({width:375,height:812});
  await page.click('.tab[data-tab="clips"]');
  await page.waitForFunction(()=>!document.querySelector('#clips-more').disabled);
  await page.screenshot({path:join(dir,'phone-clips.png')});
  await page.setViewportSize({width:1280,height:900});
  await page.click('.tab[data-tab="sources"]');
  await page.waitForFunction(()=>!document.querySelector('#sources-more').disabled);
  await page.screenshot({path:join(dir,'desktop-sources.png')});
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({status:'PASS',checks:['saved clip playback','source and clip pagination','search clear and request ownership','detail request ownership','phone modal close on error','closed proxy polling cancellation','permanent speed with source-time marks','save response ownership','failed sprite retry and blob disposal','320–1280px layout'],artifacts:dir}));
} finally { await browser.close(); }
