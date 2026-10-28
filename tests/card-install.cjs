const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const id='11111111-1111-4111-8111-111111111111',token='22222222-2222-4222-8222-222222222222';
const base='http://127.0.0.1:8765/';
(async()=>{
 const server=require('node:http').createServer((req,res)=>{const path=require('node:path').join(require('node:path').resolve(__dirname,'..'),new URL(req.url,base).pathname==='/'?'index.html':new URL(req.url,base).pathname);try{const data=require('node:fs').readFileSync(path);res.setHeader('Content-Type',path.endsWith('.js')?'text/javascript':path.endsWith('.css')?'text/css':path.endsWith('.png')?'image/png':path.endsWith('.webmanifest')?'application/manifest+json':'text/html');res.end(data)}catch{res.statusCode=404;res.end()}});await new Promise(r=>server.listen(8765,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH||undefined,args:['--no-sandbox']});
 async function context({ios=false,standalone=false,registered=true,business='Comercio de prueba'}={}){
  const ctx=await browser.newContext({viewport:{width:390,height:844},userAgent:ios?'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1':'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131.0.0.0 Mobile Safari/537.36'});
  if(standalone)await ctx.addInitScript(()=>Object.defineProperty(navigator,'standalone',{value:true}));
  const calls=[];let reg=registered;
  await ctx.route('**/*',async route=>{
   const req=route.request(),url=new URL(req.url());
   if(url.origin===new URL(base).origin)return route.continue();
   if(!url.pathname.includes('/rest/v1/')&&!url.pathname.includes('/functions/v1/'))return route.abort();
   const body=req.postDataJSON();calls.push({path:url.pathname,body});let data={};
   if(url.pathname.endsWith('nfc_profiles'))data=[{id,business,name:business,goal:5,reward:'10% de descuento',phone:'5493435000000',theme_primary:'#1686ff'}];
   else if(url.pathname.endsWith('/nfc_card'))data=reg?{name:'Cliente prueba',points:2,visits:2,goal:5,reward:'10% de descuento'}:null;
   else if(url.pathname.endsWith('/nfc_register_card_v3')){reg=true;data={name:'Cliente prueba',points:0,visits:0,goal:5};}
   else if(url.pathname.endsWith('look-employees'))data={employees:[]};
   await route.fulfill({json:data});
  });return{ctx,calls,page:await ctx.newPage()};
 }
 for(const ios of [false,true]){
  const {ctx,page,calls}=await context({ios});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(base+'?nfc='+id+'#card='+token);await page.locator('#lookSaveCard').waitFor();
  assert.match(await page.locator('link[rel=manifest]').getAttribute('href'),/card.webmanifest/);
  assert.equal(new URL(page.url()).hash,'#card='+token);
  await page.getByRole('button',{name:'Guardar mi tarjeta en el inicio',exact:true}).click();
  assert(await page.locator('#lookSaveGuide').evaluate(e=>e.open));
  assert.match(await page.locator('#lookSaveSteps').innerText(),ios?/Compartir/:/menú/);
  assert(await page.locator('#lookSaveGuide').evaluate(e=>e.getBoundingClientRect().width<=window.innerWidth));
  
  await page.getByRole('button',{name:'Entendido',exact:true}).click();
  await page.reload();await page.locator('#lookSaveCard').waitFor();assert.equal(calls.filter(x=>x.path.endsWith('/nfc_card')).at(-1).body.p_token,token);
  assert.equal(errors.length,0,errors.join('\n'));await ctx.close();console.log('PASS',ios?'iPhone instructions + personal URL reload':'Android instructions + personal URL reload');
 }
 const standalone=await context({ios:true,standalone:true});await standalone.page.goto(base+'?nfc='+id+'#card='+token);await standalone.page.locator('#cardState').waitFor();assert.equal(await standalone.page.locator('#lookSaveCard').count(),0);assert.equal(standalone.calls.find(x=>x.path.endsWith('/nfc_card')).body.p_token,token);await standalone.ctx.close();console.log('PASS isolated home-screen context opens same card and hides install prompt');
 const fresh=await context({registered:false});await fresh.page.goto(base+'?nfc='+id+'&ref=AMIGO');await fresh.page.locator('#customerForm').waitFor();assert.equal(await fresh.page.locator('#lookSaveCard').count(),0);
 
 await fresh.page.locator('#customerName').fill('Cliente prueba');await fresh.page.locator('#customerPhone').fill('5493435000000');
 await fresh.page.locator('#customerForm input[type=checkbox][required]').check();
 await fresh.page.locator('#customerForm button').click();await fresh.page.locator('#lookSaveGuide[open]').waitFor();
 const cdp=await fresh.ctx.newCDPSession(fresh.page);const manifest=await cdp.send('Page.getAppManifest');assert.equal(manifest.errors.length,0);assert.equal(manifest.manifest.startUrl,fresh.page.url());assert.equal(new URL(fresh.page.url()).searchParams.has('ref'),false);assert(new URL(fresh.page.url()).hash.startsWith('#card='));assert.equal(fresh.calls.find(x=>x.path.endsWith('/nfc_register_card_v3')).body.p_referral,'AMIGO');await fresh.ctx.close();console.log('PASS registration offers guide only after success and preserves referral attribution');
 for(const business of ['Look Phone','Ponte Coqueta']){const t=await context({business});await t.page.goto(base+'?nfc='+id+'#card='+token);await t.page.locator('#lookSaveCard').waitFor();await t.page.locator('#lookSaveAgain').click();assert(await t.page.locator('#lookSaveGuide').evaluate(e=>e.open));await t.ctx.close();console.log('PASS shortcut controls in '+business);}
 const auth=await context();await auth.page.goto(base);await auth.page.locator('#auth').waitFor();assert.equal(await auth.page.locator('#lookSaveCard').count(),0);assert.match(await auth.page.locator('link[rel=manifest]').getAttribute('href'),/^manifest.webmanifest/);await auth.ctx.close();console.log('PASS merchant login unchanged');
 await browser.close();server.close();
})().catch(e=>{console.error(e);process.exit(1)});
