const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
(async()=>{
 const base='http://127.0.0.1:8766';
 const server=require('node:http').createServer((req,res)=>{try{const file=path.join(__dirname,'..',new URL(req.url,base).pathname==='/'?'index.html':new URL(req.url,base).pathname);res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file));}catch{res.statusCode=404;res.end();}});
 await new Promise(r=>server.listen(8766,'127.0.0.1',r));
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH,args:['--no-sandbox']});
 try{
 const page=await browser.newPage();await page.route('**/*',route=>new URL(route.request().url()).origin===base?route.continue():route.abort());await page.goto(base);await page.locator('#auth').waitFor();
 await page.evaluate(()=>{
  window.testProfile='11111111-1111-4111-8111-111111111111';
  session={user:{id:'owner'}};profiles=[{id:testProfile,business:'Prueba',goal:10,active:true}];
  clients=Array.from({length:8},(_,i)=>({id:'old'+i,profile_id:testProfile,name:'Ana '+i,phone:'343500'+i,points:1,created_at:'2026-01-01'}));
  events=clients.map(c=>({client_id:c.id,kind:'visit',created_at:'2026-10-27'}));
  window.newClient={id:'22222222-2222-4222-8222-222222222222',profile_id:testProfile,name:'Ana Nueva',phone:'3439991234',points:0,created_at:'2026-10-28'};
  window.remoteClients=[...clients,newClient];window.readPaths=[];
  readAll=async url=>{readPaths.push(url);return remoteClients;};
  window.sales=[];request=async(name,{body:args})=>{sales.push({name,args});return {};};
  loadAdmin=async()=>{renderQuickVisit();};
  view('admin');setAdminTab('home',{scroll:false});renderQuickVisit();
 });
 assert.equal(await page.locator('[data-quick-visit]').count(),8);
 await page.locator('[data-launch=purchase]').click();
 await page.locator('[data-quick-visit="22222222-2222-4222-8222-222222222222"]').waitFor();
 assert.match(await page.locator('.quick-visit-info').first().innerText(),/Ana Nueva/);
 await page.locator('#quickVisitSearch').fill('Ana');assert.equal(await page.locator('[data-quick-visit]').count(),9);
 await page.locator('#quickVisitSearch').fill('3439991234');assert.equal(await page.locator('[data-quick-visit]').count(),1);
 const amount=page.locator('[data-quick-amount]');await amount.fill('12500');
 await page.evaluate(()=>refreshQuickVisitClients());assert.equal(await amount.inputValue(),'12500');
 await page.locator('[data-quick-visit]').click();
 assert.equal(await page.evaluate(()=>sales.length),1);assert.equal(await page.evaluate(()=>sales[0].args.p_sale_amount),12500);assert.equal(await page.evaluate(()=>sales[0].args.p_client), '22222222-2222-4222-8222-222222222222');
 assert(await page.locator('[data-quick-visit]').isDisabled());
 await page.waitForFunction(()=>document.querySelector('[data-quick-amount="22222222-2222-4222-8222-222222222222"]')?.value==='');
 assert.equal(await page.locator('[data-quick-amount="22222222-2222-4222-8222-222222222222"]').getAttribute('placeholder'),'Importe 
 console.log('PASS new remote zero-point card appears on purchase focus, newest first, all matching names, phone lookup, amount preserved and purchase sent once');
 await page.evaluate(async()=>{
   let finish;readAll=()=>new Promise(r=>finish=r);const pending=refreshQuickVisitClients();profiles=[{id:'another',business:'Otro'}];clients=[];finish([newClient]);await pending;if(clients.length)throw Error('Stale merchant response applied');
 });console.log('PASS late response cannot cross merchant scope');
 }finally{await browser.close();server.close();}
})().catch(e=>{console.error(e);process.exit(1)});
);
 assert(await page.evaluate(()=>readPaths.every(p=>p.includes('profile_id=eq.'+testProfile))));
 console.log('PASS new remote zero-point card appears on purchase focus, newest first, all matching names, phone lookup, amount preserved and purchase sent once');
 await page.evaluate(async()=>{
   let finish;readAll=()=>new Promise(r=>finish=r);const pending=refreshQuickVisitClients();profiles=[{id:'another',business:'Otro'}];clients=[];finish([newClient]);await pending;if(clients.length)throw Error('Stale merchant response applied');
 });console.log('PASS late response cannot cross merchant scope');
 }finally{await browser.close();server.close();}
})().catch(e=>{console.error(e);process.exit(1)});
