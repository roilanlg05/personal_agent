const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../Resources/background.js'), 'utf8');
function setup(cookies, response = {ok:true, verified:true}) {
  const calls = [];
  const browser = {
    cookies: {getAll: async filter => {
      calls.push({filter});
      if (!Array.isArray(cookies)) return filter.url?.includes('atoz-apps') ? cookies.api : cookies.login;
      if (!filter.url) return cookies;
      const url = new URL(filter.url);
      return cookies.filter(c => {
        const d=c.domain.replace(/^\./,''); const path=c.path || '/';
        return (c.hostOnly ? url.hostname===d : url.hostname===d || url.hostname.endsWith('.'+d)) &&
          (url.pathname===path || (url.pathname.startsWith(path) && (path.endsWith('/') || url.pathname[path.length]==='/'))) &&
          (!c.expirationDate || c.expirationDate > Date.now()/1000);
      });
    }, onChanged:{addListener(){}}},
    runtime:{onMessage:{addListener(){}}}, tabs:{
      create:async options=>{calls.push({navigation:options});return {id:99,status:'complete'};},
      get:async()=>({id:99,status:'complete',url:'https://atoz-apps.amazon.work/'}),
      remove:async()=>{},onUpdated:{addListener(){},removeListener(){}}}

  };
  const ctx = vm.createContext({browser, URL, Date, atob, AbortSignal, setTimeout:(fn,ms)=>setTimeout(fn,ms<=2000?0:ms), clearTimeout,
    fetch: async (url, req) => {calls.push({url, payload:JSON.parse(req.body)});
      return {ok: response.ok, status: response.status || 200, json:async()=>response};}
  });
  vm.runInContext(source, ctx);
  return {run: expr => vm.runInContext(expr, ctx), calls};
}
function cookie(name, value, extra={}) {
  return {name,value,domain:'.amazon.work',path:'/',...extra};
}
function token(exp = Date.now()/1000+3600) {
  return 'eyJhbGciOiJub25lIn0.'+Buffer.from(JSON.stringify({sub:'12345',exp})).toString('base64url')+'.sig';
}
test('generic Amazon cookies and five preferences never authenticate', async()=>{
  for(const cookies of [[cookie('session-id','store')],Array.from({length:5},(_,i)=>cookie('pref'+i,'x'))]) {
    const s=setup(cookies); const res=await s.run('checkAndSync(true)');
    assert.equal(res.success,false); assert.equal(res.reason,'missing_token');
    assert.equal(s.calls.filter(c=>c.payload).length,0);
  }
});
test('expired, nearly expired and malformed tokens never sync, even when forced', async()=>{
  for(const val of [token(1),token(Date.now()/1000+30),'bad']) {
    const s=setup([cookie('atoz-oauth-token',val)]);
    assert.equal((await s.run('checkAndSync(true)')).success,false);
    assert.equal(s.calls.filter(c=>c.payload).length,0);
  }
});
test('Python order: login cookies, API navigation, then API cookies overwrite duplicate names', async()=>{
  const loginToken=token();
  const s=setup({login:[cookie('atoz-oauth-token',loginToken,{domain:'atoz.amazon.work',hostOnly:true}),
    cookie('login-only','kept',{domain:'atoz.amazon.work',hostOnly:true}),cookie('same','login')],
    api:[cookie('same','api'),cookie('api-only','kept',{domain:'atoz-apps.amazon.work',hostOnly:true})]});
  const res=await s.run('checkAndSync()');assert.equal(res.verified,true);
  assert.equal(s.calls[0].filter.url,'https://atoz.amazon.work/');
  assert.equal(s.calls[1].filter.url,'https://atoz-apps.amazon.work/');
  assert.equal(s.calls.find(c=>c.navigation).navigation.url,'https://atoz-apps.amazon.work/');
  const payload=s.calls.find(c=>c.payload).payload;
  assert.equal(payload.verify,true);assert.equal(payload.credentials.employeeId,'204193941');
  assert.equal(payload.credentials.cookie,
    'atoz-oauth-token='+loginToken+'; login-only=kept; same=api; api-only=kept');
});
test('a valid OAuth token needs no sub claim because Python uses configured employee ID',async()=>{
  const raw='header.'+Buffer.from(JSON.stringify({exp:Date.now()/1000+3600})).toString('base64url')+'.sig';
  const s=setup([cookie('atoz-oauth-token',raw)]);
  const state=await s.run('checkAndSync()');
  assert.equal(state.success,true);assert.equal(state.employeeId,'204193941');
});
test('old server cannot produce false verification',async()=>{
  const s=setup([cookie('atoz-oauth-token',token())],{ok:true});
  assert.equal((await s.run('checkAndSync()')).reason,'backend_update_required');
});
test('Amazon rejection is returned without saving a successful cache',async()=>{
  const s=setup([cookie('atoz-oauth-token',token())],{ok:false,status:422,error:{code:'amazon_session_rejected'}});
  assert.equal((await s.run('checkAndSync()')).reason,'amazon_session_rejected');
  assert.equal((await s.run('checkAndSync()')).success,false);
  assert.equal(s.calls.filter(c=>c.payload).length,2);
});
test('popup metadata never exposes the raw header',async()=>{
  const s=setup([cookie('atoz-oauth-token',token())]);
  const state=await s.run('collectAllCookies().then(c => ({count:c.length,...sessionState(c)}))');
  assert.equal(state.isActive,true);assert.equal(state.cookie,undefined);assert.equal(state.cookies,undefined);
});
test('concurrent triggers share a request; unchanged verified cookies are cached',async()=>{
  const s=setup([cookie('atoz-oauth-token',token())]);
  await s.run('Promise.all([checkAndSync(),checkAndSync()])');
  assert.equal(s.calls.filter(c=>c.payload).length,1);
  assert.equal((await s.run('checkAndSync()')).cached,true);
});

test('expired stored cookies are replaced by newly issued cookies on the next check',async()=>{
  const cookies=[cookie('atoz-oauth-token',token(1))];
  const s=setup(cookies);
  assert.equal((await s.run('checkAndSync()')).reason,'expired_token');
  const fresh=token();cookies[0]=cookie('atoz-oauth-token',fresh);
  assert.equal((await s.run('checkAndSync()')).verified,true);
  assert.ok(s.calls.find(c=>c.payload).payload.credentials.cookie.includes(fresh));
});
test('restoring an open Safari page rechecks the session and never redirects on stale cookies',()=>{
  const events={}, docEvents={};let attempts=0;
  const document={visibilityState:'visible',readyState:'complete',
    addEventListener:(name,fn)=>{docEvents[name]=fn;}};
  const location={href:'https://atoz.amazon.work/home'};
  const ctx=vm.createContext({browser:{runtime:{sendMessage:(_req,cb)=>{attempts++;cb({success:false,reason:'expired_token'});}}},
    document,location,window:{location,addEventListener:(name,fn)=>{events[name]=fn;}},
    MutationObserver:class {observe(){}},setInterval(){},setTimeout(){}});
  const content=fs.readFileSync(require('node:path').join(__dirname,'../Resources/content_script.js'),'utf8');
  vm.runInContext(content,ctx);
  vm.runInContext('hasSynced = true',ctx);
  events.pageshow();docEvents.visibilitychange();
  assert.equal(attempts,2);
  assert.equal(vm.runInContext('hasSynced',ctx),false);
  assert.equal(location.href,'https://atoz.amazon.work/home');
});

test('diagnostic reports contain no cookie values, JWT claims values or header',async()=>{
  const raw=token();const s=setup([cookie('atoz-oauth-token',raw),cookie('atoz-auth-session','secret-value')]);
  await s.run('reportDiagnostics({reason:"missing_token"})');
  const sent=s.calls.find(c=>c.payload);
  assert.ok(sent.url.endsWith('amazon-atoz-diagnostics'));
  assert.doesNotMatch(JSON.stringify(sent.payload),/secret-value|12345|atoz-oauth-token=/);
  assert.ok(!JSON.stringify(sent.payload).includes(raw));
  assert.equal(sent.payload.credentials.sources[0].cookies[0].token.hasSub,true);
});

test('configured identity and origins match the Python source of truth',()=>{
  const python=fs.readFileSync(require('node:path').join(__dirname,'../../amazon_scheduler.py'),'utf8');
  const expected=python.match(/^EMPLOYEE_ID\s*=\s*"([^"]+)"/m)[1];
  const s=setup([]);
  assert.equal(s.run('EMPLOYEE_ID'),expected);
  assert.equal(s.run('new URL(LOGIN_URL).hostname'),python.match(/^LOGIN_DOMAIN\s*=\s*"([^"]+)"/m)[1]);
  assert.equal(s.run('new URL(API_ORIGIN).hostname'),python.match(/^AUTH_DOMAIN\s*=\s*"([^"]+)"/m)[1]);
});

test('Safari capture uses the cookie store belonging to the source tab', async()=>{
  const s=setup([]);
  await s.run(`api.cookies.getAllCookieStores=async()=>[
    {id:'default-stale',tabIds:[]},{id:'current-profile',tabIds:[7]}];
    selectCookieContext({tab:{id:7,windowId:2,url:'https://atoz.amazon.work/home'}})`);
  await s.run('collectAllCookies()');
  assert.equal(s.calls[0].filter.storeId,'current-profile');
  assert.equal(s.calls[0].filter.url,'https://atoz.amazon.work/home');
  assert.equal(s.calls[1].filter.storeId,'current-profile');
});
