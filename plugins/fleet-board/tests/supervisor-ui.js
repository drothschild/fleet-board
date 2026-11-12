"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const loadBoard = require("./supervisor-ui-harness");

const boardPath = path.join(__dirname, "../scripts/board-web/static/board.js");
const hostile = '<img src=x onerror="alert(1)">';
const control = "\u0001\u202e";
const states = [{key:"backlog",name:"Backlog"},{key:"ready",name:"Ready"},{key:"in_progress",name:"In Progress"}];
const baseCard = {number:4,title:hostile,body:"repair me",labels:[],comments:[],state:"bogus",known:false,
  stuck:null,activity:{action:"launch",elapsed_seconds:61}};
const snapshot = {schema_version:2,revision:7,run_id:"run-1",mode:"running",pause_reason:null,pid:4242,root:"/repo",
  desired_mode:"running",phase:"running",ready:true,active:[],lane:null,provider_health:{},run_tokens:{},
  capacity:{slots:2,global_cap:4,per_provider:{[hostile]:1}},
  queue:{ready:2,running:1,waiting:3,attention:1},
  last_error:hostile,cards:[baseCard]};
const tok = (total, extra) => ({input:total,output:0,cache_read:0,cache_write:0,total,unknown:0,partial:false,...(extra||{})});
const usage = {run:tok(15),all_time:tok(1234),planner:tok(7)};
// What GET /api/supervisor answers while no supervisor runs: 200, running false, the ledger totals.
const notRunning = (extra) => ({running:false,run:null,all_time:tok(1234),planner:tok(7),...(extra||{})});
const json = value => JSON.parse(JSON.stringify(value));
function response(status, data) { return {ok:status>=200&&status<300,status,json:async()=>data}; }
function fakeFetch(options={}) {
  const calls=[], queues=new Map(); let current=json(options.snapshot||snapshot);
  function enqueue(url, ...items) { queues.set(url, (queues.get(url)||[]).concat(items)); }
  async function fetch(url, init={}) {
    const method=init.method||"GET", body=init.body?JSON.parse(init.body):null;
    calls.push({url,method,body});
    const queue=queues.get(url);
    if(queue&&queue.length) { const item=queue.shift(); if(item instanceof Error) throw item; if(typeof item==="function") return item({url,method,body,current,setSnapshot}); return item; }
    if(url.split("?")[0]==="/api/board") return response(200,{repo:"acme/toy",states:options.states||states,cards:options.cards||current.cards||[],run:options.run||{state:"idle"}});
    if(url==="/api/supervisor") {
      if(options.supervisor===false) return response(404,{error:"missing"});
      if(options.notRunning) return response(200,notRunning(options.notRunning===true?{}:options.notRunning));
      return response(200,{...current,running:true});
    }
    if(url==="/api/usage") return response(200,options.usage||usage);
    if(url==="/api/run") return response(200,options.run||{state:"idle"});
    if(url==="/api/cards/4"&&method==="GET") return response(200,current.cards[0]);
    if(url==="/api/cards/4/usage") return response(200,options.cardUsage||{card:4,totals:tok(0),columns:[]});
    if(url==="/api/cards/4/move") return response(200,current.cards[0]);
    return response(404,{error:"unexpected fake route"});
  }
  function setSnapshot(value){current=json(value);}
  return {fetch,calls,enqueue,setSnapshot,get snapshot(){return current;}};
}
const realShapes=()=>JSON.parse(require("fs").readFileSync(process.env.SUPERVISOR_REAL_SHAPES,"utf8"));
const failures=[];
async function check(name, fn) {
  try { await fn(); console.log("ok - "+name); }
  catch(error) { failures.push({name,reason:error.message}); console.log("not ok - "+name+" — "+error.message); }
}
function countCalls(fake, url, method) { return fake.calls.filter(c=>c.url===url&&(!method||c.method===method)).length; }
function make(fake, options) { return loadBoard(boardPath,fake.fetch,options); }
function descendants(root) { return [root,...root.all()]; }
function h0(){ return {pageHtml:require("fs").readFileSync(path.join(path.dirname(boardPath),"index.html"),"utf8")}; }
async function main() {
  let fake,ui;
  await check("1a. Supervisor mode detects 200 and performs read-only initial load",async()=>{
    fake=fakeFetch(); ui=make(fake); await ui.flush(); await ui.waitForRequests();
    assert.ok(countCalls(fake,"/api/supervisor")>=1,"GET supervisor snapshot missing");
    assert.ok(countCalls(fake,"/api/board")>=1,"board load missing");
    assert.equal(fake.calls.filter(c=>c.method==="POST").length,0,"mutating request on load/poll");
    assert.ok(ui.$("supervisor-status"),"missing supervisor status element");
    assert.equal(ui.$("supervisor-status").hidden,false,"supervisor status not shown for 200");
  });
  await check("1b. A 404, a thrown fetch or a bad reply is retried, and the page has no tick-wrapper Start or Stop",async()=>{
    const f=fakeFetch({supervisor:false}), h=make(f); await h.flush(); await h.waitForRequests();
    for(const id of ["start-btn","stop-btn","log-btn","run-pill","run-hours"]) assert.doesNotMatch(h.pageHtml,new RegExp('id="'+id+'"'),"the page still has the tick wrapper's "+id);
    assert.equal(countCalls(f,"/api/run"),0,"the page polled the removed /api/run route");
    assert.equal(h.$("supervisor").hidden,true,"supervisor shown before detection succeeded");
    const first=countCalls(f,"/api/supervisor"); assert.ok(h.timers.length>0,"no retry timer scheduled");
    f.enqueue("/api/supervisor",new Error("network down"),response(500,{error:"boom"}),response(200,{ok:true}));
    for(let i=0;i<3;i++) { await h.fireTimers(); assert.equal(h.$("supervisor").hidden,true,"adopted a bad detection reply"); }
    assert.ok(countCalls(f,"/api/supervisor")>=first+3,"detection did not retry after a throw, a 500 and a bad reply");
    assert.equal(f.calls.filter(c=>c.method==="POST").length,0,"a failed detection sent a command");
    f.enqueue("/api/supervisor",response(200,{running:false,run:null,all_time:tok(1),planner:tok(1)})); await h.fireTimers();
    assert.equal(h.$("supervisor").hidden,false,"a later good reply did not enter supervisor mode");
    assert.match(h.$("supervisor-status").textContent,/not running/i);
  });
  await check("2. Status exposes the v2 snapshot fields and truthful occupancy, with no dollars or boot registration",async()=>{
    const s=ui.$("supervisor-status"), t=s.textContent;
    for(const value of ["running","ready","4","2","3","attention",hostile])
      assert.ok(t.includes(value),"status missing snapshot field "+value);
    assert.doesNotMatch(t,/\$|budget|boot registration|reboot/i,"a removed field (dollars, budget, boot registration) is shown");
    const paused=make(fakeFetch({snapshot:{...json(snapshot),mode:"paused",desired_mode:"paused",phase:"paused",pause_reason:"provider claude is unhealthy"}}));
    await paused.flush(); await paused.waitForRequests();
    assert.match(paused.$("supervisor-status").textContent,/paused.*provider claude is unhealthy/i,"pause reason not shown");
    const f=fakeFetch({snapshot:{...json(snapshot),capacity:{...snapshot.capacity,slots:null}}}), h=make(f); await h.flush(); await h.waitForRequests();
    assert.match(h.$("supervisor-status").textContent,/occupancy unknown/i,"null occupancy rendered as zero/omitted");
  });
  await check("3a. Start click sends revision-bound command and waits for ready poll",async()=>{
    const paused={...json(snapshot),desired_mode:"paused",phase:"paused",mode:"paused"};
    const f=fakeFetch({snapshot:paused}), h=make(f); await h.flush(); await h.waitForRequests();
    f.enqueue("/api/supervisor/start",response(202,{command_id:"c1",state_revision:8,desired_mode:"running",phase:"starting"}));
    const button=h.$("supervisor-start-btn"); assert.equal(button.tagName,"BUTTON","missing real Start button"); await button.fire("click"); await h.waitForRequests();
    const call=f.calls.find(c=>c.url==="/api/supervisor/start"&&c.method==="POST");
    assert.ok(call,"Start click did not POST"); assert.ok(call.body.request_id,"request id missing"); assert.equal(call.body.expected_revision,7);
    assert.match(h.$("supervisor-status").textContent,/starting|acknowledged/i,"202 acknowledgement not shown");
    assert.doesNotMatch(h.$("supervisor-status").textContent,/\bRunning\b/,"202 treated as observed Running");
    f.setSnapshot({...json(snapshot),ready:true,phase:"running"}); await h.fireTimers();
    assert.match(h.$("supervisor-status").textContent,/running/i,"fresh ready poll did not render Running");
  });
  await check("3b. Pause, Stop menu Drain/Cancel and keyboard dismissal are real interactions",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    const pause=h.$("supervisor-pause-btn"); assert.ok(pause,"Pause control absent"); await pause.fire("click");
    assert.ok(f.calls.some(c=>c.url==="/api/supervisor/pause"&&c.method==="POST"),"Pause click did not POST");
    const stop=h.$("supervisor-stop-btn"); assert.ok(stop,"Stop menu trigger absent"); await stop.fire("click");
    const menu=h.$("supervisor-stop-menu"); assert.equal(menu.hidden,false,"Stop menu did not open");
    const drain=h.$("supervisor-drain-btn"); assert.ok(drain,"Drain action absent"); await drain.fire("click");
    assert.ok(f.calls.some(c=>c.url==="/api/supervisor/stop"&&c.body.mode==="drain"),"Drain mode absent");
    await stop.fire("click"); const cancel=h.$("supervisor-cancel-btn"); assert.ok(cancel,"Cancel action absent"); await cancel.fire("click");
    assert.ok(f.calls.some(c=>c.url==="/api/supervisor/stop"&&c.body.mode==="cancel"),"Cancel mode absent");
    await stop.fire("click"); const ev=await h.key(menu,"Escape"); assert.ok(ev.defaultPrevented,"Escape not consumed");
    assert.equal(menu.hidden,true,"Escape did not close Stop menu"); assert.equal(h.document.activeElement,stop,"focus not returned to trigger");
  });
  await check("3c. Lost response reuses request id; new action and success use fresh ids",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    f.enqueue("/api/supervisor/pause",new Error("lost response"),response(202,{}),response(202,{}));
    await h.$("supervisor-pause-btn").fire("click"); await h.$("supervisor-pause-btn").fire("click");
    let calls=f.calls.filter(c=>c.url==="/api/supervisor/pause"&&c.method==="POST");
    assert.equal(calls.length,2); assert.equal(calls[0].body.request_id,calls[1].body.request_id,"lost response changed id");
    await h.$("supervisor-pause-btn").fire("click"); calls=f.calls.filter(c=>c.url==="/api/supervisor/pause"&&c.method==="POST");
    assert.notEqual(calls[1].body.request_id,calls[2].body.request_id,"success did not clear id");
  });
  await check("3d. 409 refreshes body, 503 reason and 400 message are surfaced",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    f.enqueue("/api/supervisor/pause",response(409,{error:"revision conflict",snapshot:{...json(snapshot),revision:12,phase:"recovering"}}));
    await h.$("supervisor-pause-btn").fire("click"); await h.flush();
    assert.equal(h.ctx.__test.S.supervisor.revision,12,"409 state body not adopted");
    assert.match(h.$("supervisor-status").textContent,/recovering/i,"409 state not rendered");
    assert.equal(countCalls(f,"/api/supervisor/pause","POST"),1,"409 resent command");
    const g=fakeFetch({notRunning:true}), k=make(g); await k.flush(); await k.waitForRequests();
    g.enqueue("/api/supervisor/start",response(503,{reason:"maintenance window"}));
    await k.$("supervisor-start-btn").fire("click"); assert.match(k.document.body.textContent,/maintenance window/i,"503 reason absent");
    g.enqueue("/api/supervisor/start",response(400,{message:"invalid request"}));
    await k.$("supervisor-start-btn").fire("click"); assert.match(k.document.body.textContent,/invalid request/i,"400 message absent");
  });
  await check("3e. Allowed mode matrix enables only valid controls",async()=>{
    const paused={...json(snapshot),desired_mode:"paused",phase:"stopped",ready:true};
    const f=fakeFetch({snapshot:paused}), h=make(f); await h.flush(); await h.waitForRequests();
    assert.equal(h.$("supervisor-start-btn").disabled,false,"Start (which resumes) unavailable while paused");
    assert.equal(h.$("supervisor-resume-btn").disabled,false,"Resume unavailable while paused");
    assert.equal(h.$("supervisor-pause-btn").disabled,true,"Pause available while paused");
    f.setSnapshot({...paused,desired_mode:"running",phase:"running"}); await h.fireTimers();
    assert.equal(h.$("supervisor-pause-btn").disabled,false,"Pause unavailable while running");
    assert.equal(h.$("supervisor-resume-btn").disabled,true,"Resume active while running");
    assert.equal(h.$("supervisor-start-btn").disabled,true,"Start active while running");
  });
  await check("4. A failed poll preserves the last snapshot and gates mutations",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests(); const s=h.$("supervisor-status");
    const prior=h.ctx.__test.S.supervisor; assert.ok(prior,"no snapshot adopted");
    f.enqueue("/api/supervisor",new Error("network down")); await h.fireTimers();
    assert.match(s.textContent,/occupancy unknown/i,"failed poll did not mark stale"); assert.match(s.textContent,/network down|no answer/i);
    assert.equal(h.ctx.__test.S.supervisor,prior,"a failed poll dropped the last snapshot");
    for(const id of ["supervisor-start-btn","supervisor-pause-btn","supervisor-resume-btn","supervisor-stop-btn"]){
      const b=h.$(id); assert.equal(b.disabled,true,id+" enabled stale"); assert.ok(b.title||b.getAttribute("aria-describedby"),id+" lacks disabled explanation");
    }
    assert.equal(h.$("supervisor-retry-btn").hidden,false,"retry hidden while stale"); assert.equal(h.$("supervisor-retry-btn").disabled,false,"retry connection not live");
    f.enqueue("/api/supervisor",response(503,{error:"maintenance"})); await h.$("supervisor-retry-btn").fire("click"); await h.flush();
    assert.match(s.textContent,/maintenance/,"a 503 reason was not shown");
    f.setSnapshot({...json(snapshot),revision:8}); await h.fireTimers();
    assert.notEqual(h.ctx.__test.S.supervisor,prior,"recovery poll did not replace snapshot"); assert.equal(h.$("supervisor-pause-btn").disabled,false);
    assert.equal(h.$("supervisor-retry-btn").hidden,true,"retry still offered after recovery");
  });
  await check("5. Removed routes (events, execution, resolve, release-reservations) are never called and their UI is gone",async()=>{
    const f=fakeFetch({cardUsage:{card:4,totals:tok(0),columns:[]}}), h=make(f); await h.flush(); await h.waitForRequests();
    await h.fireTimers(); await h.setHidden(true); await h.setHidden(false);
    const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); await card.fire("click"); await h.fireTimers();
    const removed=f.calls.filter(c=>/\/events|\/execution|\/resolve|release-reservations/.test(c.url));
    assert.deepEqual(removed.map(c=>c.url),[],"a removed route was called");
    const html=h0().pageHtml;
    for(const id of ["dr-exec-sec","dr-resolve-retry","dr-release-reservations","supervisor-timeline","supervisor-note"]) assert.doesNotMatch(html,new RegExp('id="'+id+'"'),id+" is still in the page");
    assert.doesNotMatch(html,/no scheduler is wired|boot registration|execution is disabled by default/i,"deferral/boot text is still in the page");
    assert.equal(f.calls.filter(c=>c.method==="POST").length,0,"a poll issued a command");
  });
  await check("5b. Visibility backs polling off and resumes",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    await h.setHidden(true); const polls=countCalls(f,"/api/supervisor"); await h.fireTimers(); assert.ok(countCalls(f,"/api/supervisor")>=polls,"hidden polling stopped entirely");
    await h.setHidden(false); assert.ok(h.timers.length>0,"visible document did not resume polling");
  });
  await check("token strip shows run and all-time and planner",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests(); const t=h.$("supervisor-tokens").textContent;
    assert.match(t,/This run: 15 tokens/); assert.match(t,/All time: 1,234 tokens/); assert.match(t,/Planner: 7 tokens/);
    assert.ok(t.indexOf("This run")<t.indexOf("All time")&&t.indexOf("All time")<t.indexOf("Planner"),"strip order is run, all time, planner");
    // a partial total is a lower bound, and an input of 0 beside unknown usage is never an exact count
    const u={run:tok(0,{unknown:2,partial:true}),all_time:tok(1234,{partial:true,unknown:3}),planner:tok(7)};
    const g=fakeFetch({usage:u}), k=make(g); await k.flush(); await k.waitForRequests(); const p=k.$("supervisor-tokens").textContent;
    assert.match(p,/This run: ≥ 0 \(some usage unknown\)/); assert.match(p,/All time: ≥ 1,234 \(some usage unknown\)/);
    assert.doesNotMatch(p,/This run: 0 tokens/,"a partial 0 shown as exact"); assert.match(p,/Planner: 7 tokens/);
    // no supervisor: no run total, but the ledger still shows; an unreadable ledger is unknown, never 0
    const n=fakeFetch({notRunning:true,usage:{run:null,all_time:tok(1234),planner:tok(7)}}), m=make(n); await m.flush(); await m.waitForRequests();
    assert.match(m.$("supervisor-tokens").textContent,/This run: none/i); assert.match(m.$("supervisor-tokens").textContent,/All time: 1,234 tokens/);
    const b=fakeFetch({notRunning:{all_time:null,planner:null,error:"usage ledger unreadable"},usage:{run:null,all_time:null,planner:null,error:"usage ledger unreadable"}}), c=make(b); await c.flush(); await c.waitForRequests();
    assert.match(c.$("supervisor-tokens").textContent,/All time: unknown/); assert.doesNotMatch(c.$("supervisor-tokens").textContent,/All time: 0/);
  });
  await check("no dollar sign rendered",async()=>{
    const run={state:"stopped",stop_reason:"nothing-dispatchable",cost:1.5,cost_estimate_usd:2.5,hours:2};
    const f=fakeFetch({run,usage:{run:tok(15),all_time:tok(1234),planner:tok(7)}}), h=make(f); await h.flush(); await h.waitForRequests();
    const ids=["board","supervisor-status","supervisor-tokens","top","stuck-banner","stuck-note"];
    for(const id of ids) assert.doesNotMatch(h.$(id).textContent,/\$|\bUSD\b|\bcost\b/i,id+" shows a dollar or cost figure: "+h.$(id).textContent);
    const g=fakeFetch({supervisor:false,run}), k=make(g); await k.flush(); await k.waitForRequests();
    for(const id of ids) assert.doesNotMatch(k.$(id).textContent,/\$|\bUSD\b|\bcost\b/i,"undetected "+id+" shows a dollar or cost figure");
    assert.doesNotMatch(h0().pageHtml.replace(/<script[\s\S]*?<\/script>/g,""),/\$|\bcost\b/i,"the page itself mentions a dollar or cost");
  });
  await check("drilldown lists actions by column",async()=>{
    const cardUsage={card:4,totals:tok(1000,{partial:true,unknown:1}),columns:[
      {column:"in_progress",totals:tok(120),actions:[
        {action:"implement",role:"implementor",model:"opus",provider:"claude",input:100,output:20,cache_read:0,cache_write:0,log:"logs/impl-1.log",started_at:"2026-11-10T17:00:00Z",ended_at:"2026-11-10T17:05:00Z"}]},
      {column:"in_review",totals:tok(880,{partial:true,unknown:1}),actions:[
        {action:"review",role:"reviewer",model:hostile,provider:"codex",input:null,output:30,cache_read:null,cache_write:5,log:null,started_at:null,ended_at:null},
        {action:"review",role:"reviewer",model:"opus",provider:"claude",input:800,output:50,cache_read:10,cache_write:0,log:"logs/rev-2.log",started_at:null,ended_at:null}]}]};
    const f=fakeFetch({cardUsage}), h=make(f); await h.flush(); await h.waitForRequests();
    const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); await card.fire("click"); await h.waitForRequests();
    assert.ok(f.calls.some(c=>c.url==="/api/cards/4/usage"&&c.method==="GET"),"drill-down not fetched");
    const cols=h.$("dr-usage-cols"), rows=cols.all().filter(n=>n.classList.contains("dr-usage-action"));
    assert.equal(rows.length,3,"one row per action"); const text=cols.textContent;
    assert.ok(text.indexOf("in_progress")>=0&&text.indexOf("in_progress")<text.indexOf("in_review"),"columns out of order");
    assert.ok(rows[0].textContent.includes("implement")&&rows[0].textContent.includes("implementor")&&rows[0].textContent.includes("opus"),"action, role, model missing: "+rows[0].textContent);
    assert.match(rows[0].textContent,/input 100/); assert.match(rows[0].textContent,/output 20/); assert.match(rows[0].textContent,/cache read 0/); assert.match(rows[0].textContent,/cache write 0/);
    assert.ok(rows[0].textContent.includes("logs/impl-1.log"),"log reference missing");
    assert.match(rows[1].textContent,/input unknown/); assert.match(rows[1].textContent,/cache read unknown/); assert.match(rows[1].textContent,/cache write 5/);
    assert.doesNotMatch(rows[1].textContent,/null|input 0\b|cache read 0\b/,"an unknown count shown as null or 0");
    assert.ok(rows[1].textContent.includes(hostile),"hostile model was dropped"); assert.match(h.$("dr-usage-total").textContent,/≥ 1,000 \(some usage unknown\)/);
    for(const n of descendants(cols)) { assert.notEqual(n.tagName,"IMG"); }
    assert.equal(h.$("dr-usage-sec").hidden,false);
  });
  await check("stuck card has card--stuck and the banner counts it",async()=>{
    const stuck=(n,kind)=>({number:n,title:"Stuck "+n,body:"",labels:[],comments:[],state:"ready",known:true,stuck:{kind,detail:"PR #"+n+" "+hostile},activity:null});
    const fine={number:6,title:"Fine",body:"",labels:[],comments:[],state:"ready",known:true,stuck:null,activity:{action:"review",elapsed_seconds:61}};
    const quiet={stuck_checked_at:1794333510,stuck_error:null,stuck_checking:false,stuck_suppressed:null};
    const mk=async(run,cards)=>{ const f=fakeFetch({notRunning:true,cards,run:{state:"idle",...run}}), h=make(f); await h.flush(); await h.waitForRequests(); return h; };
    let h=await mk(quiet,[stuck(4,"merge_pending"),stuck(5,"orphan_marker"),fine]);
    const cardOf=(h,n)=>h.$("board").all().find(x=>x.classList.contains("card")&&x.dataset.n===String(n));
    assert.ok(cardOf(h,4).classList.contains("card--stuck"),"stuck card lacks card--stuck"); assert.ok(cardOf(h,5).classList.contains("card--stuck"));
    assert.equal(cardOf(h,6).classList.contains("card--stuck"),false,"a healthy card is marked stuck");
    assert.ok(cardOf(h,4).all().some(n=>n.classList.contains("card-stuck-badge")&&n.textContent.trim()==="STUCK"),"STUCK badge missing");
    assert.equal(cardOf(h,6).all().some(n=>n.classList.contains("card-stuck-badge")),false);
    assert.ok(cardOf(h,4).textContent.includes("merge_pending")&&cardOf(h,4).textContent.includes(hostile),"stuck kind/detail missing");
    assert.ok(cardOf(h,4).textContent.includes("resolve with: supervisor.sh stuck --release 4"),"how to resolve is not said: "+cardOf(h,4).textContent);
    assert.equal(cardOf(h,6).textContent.includes("resolve with"),false);
    assert.match(cardOf(h,6).textContent,/review/,"activity not shown"); assert.doesNotMatch(cardOf(h,6).textContent,/object Object/);
    const banner=h.$("stuck-banner"); assert.equal(banner.hidden,false); assert.equal(banner.textContent.trim(),"2 stuck cards — the supervisor will not start until they are resolved");
    h=await mk(quiet,[stuck(4,"merge_pending"),fine]); assert.equal(h.$("stuck-banner").textContent.trim(),"1 stuck card — the supervisor will not start until it is resolved");
    h=await mk(quiet,[fine]); assert.equal(h.$("stuck-banner").hidden,true,"banner shown with nothing stuck");
    // still checking, nothing found yet: no banner; and the count comes from the cards, not from the run
    h=await mk({...quiet,stuck_checked_at:null,stuck_checking:true},[fine]); assert.equal(h.$("stuck-banner").hidden,true,"banner while the first check runs");
    // a check that failed is said so, and the last good findings stay visible
    h=await mk({...quiet,stuck_error:"config.sh failed: boom"},[stuck(4,"merge_pending"),fine]);
    assert.match(h.$("stuck-note").textContent,/stuck check failed: config\.sh failed: boom/); assert.equal(h.$("stuck-banner").hidden,false,"last good findings were hidden by an error");
    // suppressed: the suppression text replaces the banner
    h=await mk({...quiet,stuck_suppressed:"a run is active (pid 77)"},[fine]);
    assert.equal(h.$("stuck-banner").hidden,true,"banner shown while suppressed"); assert.match(h.$("stuck-note").textContent,/a run is active \(pid 77\)/);
    // the red border is a hard requirement, in light and dark alike
    const css=require("fs").readFileSync(path.join(path.dirname(boardPath),"board.css"),"utf8");
    assert.match(css,/\.card\.card--stuck\s*\{[^}]*border:\s*4px solid #d00000/,"card--stuck lacks a 4px solid #d00000 border");
    assert.match(css,/\.card\.card--stuck\s*\{[^}]*border:\s*4px solid #d00000\s*!important/,"the stuck border can be overridden by .card.active or dark rules");
    const dark=[...css.matchAll(/@media \(prefers-color-scheme: dark\)\s*\{([\s\S]*?)\n\}/g)].map(m=>m[1]).join("\n");
    assert.doesNotMatch(dark,/card--stuck|--stuck/,"a dark-mode rule redefines the stuck border");
    assert.match(css,/\.card-stuck-badge\s*\{/,"no STUCK badge style");
    assert.match(css,/\.card-id\s*\{[^}]*flex-wrap:\s*wrap/,"the card header cannot wrap: the STUCK badge would clip the acceptance count");
    assert.match(css,/\.card-stuck-badge\s*\{[^}]*flex:\s*none/,"the badge may shrink and clip");
  });
  await check("controls enable per mode",async()=>{
    const ids=["supervisor-start-btn","supervisor-pause-btn","supervisor-resume-btn","supervisor-stop-btn"];
    const open=async options=>{ const f=fakeFetch(options), h=make(f); await h.flush(); await h.waitForRequests(); return {f,h}; };
    const state=h=>ids.map(id=>h.$(id).disabled?"-":"+").join("");
    const need=(h,id)=>{ const b=h.$(id); assert.equal(b.disabled,true); assert.ok(b.title&&b.getAttribute("aria-describedby"),id+" disabled without a reason"); };
    // no supervisor: only Start
    let {f,h}=await open({notRunning:true}); assert.equal(state(h),"+---"); for(const id of ids.slice(1)) need(h,id);
    assert.match(h.$("supervisor-status").textContent,/not running/i); assert.equal(h.ctx.__test.S.supervisor,null,"a running:false reply was adopted as a snapshot");
    assert.equal(h.$("supervisor-retry-btn").hidden,true,"not running is not an outage");
    f.enqueue("/api/supervisor/start",response(202,{command_id:"c1",state_revision:1,desired_mode:"running",phase:"starting"}));
    await h.$("supervisor-start-btn").fire("click"); await h.waitForRequests();
    const call=f.calls.find(c=>c.url==="/api/supervisor/start"&&c.method==="POST"); assert.ok(call,"Start did not POST"); assert.ok(call.body.request_id); assert.equal(typeof call.body.expected_revision,"number");
    f.enqueue("/api/supervisor",response(200,{...json(snapshot),revision:2,running:true})); await h.fireTimers(); // the next poll finds it running
    assert.equal(state(h),"-+-+","running: Pause and Stop only"); assert.match(h.$("supervisor-status").textContent,/running/i);
    // running
    ({h}=await open({})); assert.equal(state(h),"-+-+"); need(h,"supervisor-start-btn"); assert.match(h.$("supervisor-start-btn").title,/already running/i); need(h,"supervisor-resume-btn");
    // paused: Start (the server resumes it), Resume, Stop
    ({h}=await open({snapshot:{...json(snapshot),mode:"paused",desired_mode:"paused",phase:"paused",pause_reason:"provider claude is unhealthy"}}));
    assert.equal(state(h),"+-++"); need(h,"supervisor-pause-btn");
    // stopping (the real service's shape after State.stop()): nothing to start, pause or resume
    ({h}=await open({snapshot:{...json(realShapes().stopping.status)}})); assert.equal(h.$("supervisor-start-btn").disabled,true,"Start enabled while the supervisor is stopping");
    assert.equal(h.$("supervisor-pause-btn").disabled,true); assert.equal(h.$("supervisor-resume-btn").disabled,true); assert.match(h.$("supervisor-start-btn").title,/stopping/i);
    // unhealthy providers say why
    ({h}=await open({snapshot:{...json(snapshot),provider_health:{codex:{until:1794333900,reason:"rate limited",failures:2}}}}));
    assert.match(h.$("supervisor-status").textContent,/codex.*unhealthy.*rate limited|unhealthy.*codex.*rate limited/i,"unhealthy provider reason missing");
    // a command that meets no supervisor refreshes to "not running"
    ({f,h}=await open({})); f.enqueue("/api/supervisor/pause",response(409,{error:"no supervisor is running",code:"not_running"}));
    f.enqueue("/api/supervisor",response(200,notRunning())); await h.$("supervisor-pause-btn").fire("click"); await h.waitForRequests();
    assert.match(h.$("supervisor-status").textContent,/not running/i,"409 not_running did not refresh to not running"); assert.equal(state(h),"+---");
  });
  await check("7. Hostile server values remain text throughout UI fields and usage and stuck text",async()=>{
    const bad={...json(snapshot),last_error:hostile+control,cards:[{...baseCard,title:hostile+control,activity:{action:hostile,elapsed_seconds:3},
        stuck:{kind:hostile,detail:hostile+control}}],provider_health:{[hostile]:{reason:hostile,until:1,failures:1}},
      capacity:{...snapshot.capacity,per_provider:{[hostile]:1}},reasons:[hostile],evidence:[hostile]};
    const f=fakeFetch({snapshot:bad,run:{state:"idle",stuck_error:hostile,stuck_checking:false,stuck_suppressed:null},usage:{...usage,error:hostile}}), h=make(f); await h.flush(); await h.waitForRequests();
    const text=descendants(h.document.body).map(n=>n.textContent).join(" "); assert.ok(text.includes("img"),"hostile text was dropped");
    for(const node of descendants(h.document.body)) {
      assert.notEqual(node.tagName,"IMG","hostile img created as node"); assert.notEqual(node.tagName,"SCRIPT","hostile script created as node");
      for(const key of Object.keys(node.attrs)) assert.doesNotMatch(key,/^on/i,"event-handler attribute created");
    }
    assert.equal(h.document.body.innerHTML,undefined,"fake DOM unexpectedly supports raw HTML parsing");
    assert.ok(f.calls.filter(c=>c.url==="/api/supervisor").length,"supervisor data not fetched");
  });
  await check("8a. Unknown card is repairable during active supervisor without dispatch",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); assert.ok(card,"unknown card absent");
    assert.match(card.closest("section").textContent,/Unknown/i); await card.fire("click"); assert.equal(h.$("drawer").hidden,false);
    h.$("dr-state").value="ready"; await h.$("dr-state").fire("change"); assert.equal(h.$("dr-save").disabled,false); await h.$("dr-save").fire("click");
    assert.ok(f.calls.some(c=>c.url==="/api/cards/4/move"&&c.method==="POST"),"repair Save did not work");
    assert.equal(f.calls.filter(c=>c.url.includes("/supervisor/")&&c.method==="POST").length,0,"unknown card auto-dispatched");
  });
  await check("8b. A not-running supervisor still shows unknown cards, repairable",async()=>{
    const f=fakeFetch({notRunning:true,cards:[baseCard]}), h=make(f); await h.flush(); await h.waitForRequests();
    const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); assert.ok(card); assert.match(card.closest("section").textContent,/Unknown/i);
    await card.fire("click"); h.$("dr-state").value="ready"; await h.$("dr-state").fire("change"); assert.equal(h.$("dr-save").disabled,false,"unknown card cannot be repaired when no supervisor runs");
  });
  await check("9. Keyboard, button semantics, focus order and accessible status",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests(); const status=h.$("supervisor-status");
    assert.equal(status.getAttribute("role"),"status"); assert.ok(status.getAttribute("aria-label")); assert.ok(status.getAttribute("aria-live"));
    const controls=["supervisor-start-btn","supervisor-pause-btn","supervisor-stop-btn"];
    for(const id of controls) assert.equal(h.$(id).tagName,"BUTTON",id+" is not a button");
    const positions=controls.map(id=>h.pageHtml.indexOf('id="'+id+'"'));
    assert.ok(positions.every(x=>x>=0),"controls missing from the page"); assert.deepEqual([...positions].sort((a,b)=>a-b),positions,"controls are not in logical DOM order Start, Pause, Stop");
    assert.doesNotMatch(h.pageHtml,/tabindex="[1-9]/i,"positive tabindex is an accessibility antipattern");
    const stop=h.$("supervisor-stop-btn"); await stop.fire("click"); const menu=h.$("supervisor-stop-menu");
    const first=menu.children[0]; const key=await h.key(first,"ArrowDown"); assert.ok(key.defaultPrevented,"arrow navigation not handled");
    const enter=await h.key(first,"Enter"); assert.ok(enter.defaultPrevented,"Enter not handled");
    await stop.fire("click"); const space=await h.key(stop," "); assert.ok(space.defaultPrevented,"Space not handled");
    for(const b of [h.$("supervisor-pause-btn"),h.$("supervisor-resume-btn")]) if(b.disabled) assert.ok(b.title||b.getAttribute("aria-describedby"),"disabled explanation inaccessible");
  });
  await check("10. Real service payloads (dump_real_shapes.py) drive the status bar and card controls",async()=>{
    const file=process.env.SUPERVISOR_REAL_SHAPES;
    assert.ok(file,"SUPERVISOR_REAL_SHAPES is not set: run tests through test-supervisor-ui.sh");
    const real=JSON.parse(require("fs").readFileSync(file,"utf8"));
    assert.deepEqual(Object.keys(real).sort(),["active","idle","paused","stopping"]);
    for(const k of Object.keys(real)) { assert.equal(real[k].status.running,true,k+": the shape lacks running:true"); assert.equal("unreachable" in real[k].status,false,k+": the shape still carries unreachable"); }
    const plain={number:4,title:"Real card",body:"x",labels:[],comments:[],state:"in_progress",known:true};
    const itemsOf=h=>{ const m={}; for(const n of descendants(h.$("supervisor-status")).filter(x=>x.classList.contains("sup-item"))){
      const kids=n.children.map(c=>c.textContent); if(kids.length>=2) m[kids[0]]=kids.slice(1).join(" "); else m[""]=kids[0]||n.textContent; } return m; };
    const open=async scenario=>{ const r=real[scenario];
      const f=fakeFetch({snapshot:{...json(r.status),cards:[plain]}}), h=make(f); await h.flush(); await h.waitForRequests(); return h; };
    for(const scenario of ["idle","paused","active"]) {
      const status=real[scenario].status, h=await open(scenario), items=itemsOf(h), text=h.$("supervisor-status").textContent;
      assert.equal(status.schema_version,2,scenario+": not a v2 status");
      assert.equal(items.desired,status.mode,scenario+": desired mode not shown"); assert.equal(items.phase,status.mode,scenario+": phase not shown");
      assert.match(text,/\bready\b/,scenario+": not ready"); assert.doesNotMatch(text,/not ready|readiness unknown/,scenario+": readiness not shown as ready");
      // What the supervisor does not know yet (a global cap, the board queue) reads unknown, never zero.
      assert.equal(items.ready,"unknown",scenario+": the queue the supervisor cannot see must read unknown");
      assert.match(items.slots||"",/^\d+ \/ unknown$/,scenario+": slots not populated: "+JSON.stringify(items));
      assert.match(String(items.running),/^\d+$/,scenario+": running not populated");
      assert.doesNotMatch(text,/\$|budget|boot registration/i,scenario+": a removed field is shown: "+text);
    }
    let h=await open("paused");
    assert.equal(real.paused.status.pause_reason,"provider claude is unhealthy");
    assert.match(itemsOf(h).paused||"",/provider claude is unhealthy/,"the pause reason must show");
    assert.equal(h.$("supervisor-resume-btn").disabled,false,"Resume must be available while paused");
    assert.equal(h.$("supervisor-pause-btn").disabled,true,"Pause must be disabled while paused");
    h=await open("active");
    assert.equal(real.active.status.active.length,2,"two actions in flight");
    assert.deepEqual(real.active.status.active.map(a=>a.card).sort(),[4,9],"active actions must carry their card");
    assert.equal(itemsOf(h).slots,"2 / unknown"); assert.equal(itemsOf(h).running,"2");
    assert.equal(itemsOf(h).claude,"1"); assert.equal(itemsOf(h).codex,"1");
    h=await open("idle");
    assert.equal(itemsOf(h).slots,"0 / unknown"); assert.equal(h.$("supervisor-pause-btn").disabled,false);
  });
  await check("11a. Stop renders not running (not an error), keeps Start enabled, and Start restarts",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    f.enqueue("/api/supervisor/stop",response(202,{command_id:"s1",state_revision:9,desired_mode:"stopped",phase:"stopped",status:"stopped",terminated:true}));
    await h.$("supervisor-stop-btn").fire("click"); await h.$("supervisor-drain-btn").fire("click"); await h.waitForRequests();
    // The service exits by design: the next poll finds no supervisor.
    f.enqueue("/api/supervisor",response(200,notRunning())); await h.fireTimers();
    const text=h.$("supervisor-status").textContent;
    assert.match(text,/not running/i,"the board does not say not running after Stop: "+text);
    assert.doesNotMatch(text,/unreachable|unavailable/i,"a requested Stop is shown as an error: "+text);
    assert.equal(h.$("supervisor-retry-btn").hidden,true,"Retry connection offered for a deliberate stop");
    assert.equal(h.$("supervisor-start-btn").disabled,false,"Start disabled after Stop");
    for(const id of ["supervisor-pause-btn","supervisor-resume-btn","supervisor-stop-btn"]) assert.equal(h.$(id).disabled,true,id+" enabled while not running");
    f.enqueue("/api/supervisor/start",response(202,{command_id:"s2",state_revision:10,desired_mode:"running",phase:"starting"}));
    await h.$("supervisor-start-btn").fire("click"); await h.waitForRequests();
    assert.equal(countCalls(f,"/api/supervisor/start","POST"),1,"Start after Stop did not POST");
    f.setSnapshot({...json(snapshot),revision:10}); await h.fireTimers();
    assert.match(h.$("supervisor-status").textContent,/running/i,"restart not rendered"); assert.doesNotMatch(h.$("supervisor-status").textContent,/not running/i);
    assert.equal(h.$("supervisor-pause-btn").disabled,false,"Pause not available after restart");
  });
  await check("11b. A stop that has not finished is not shown as not running",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    // the loop's real reply to stop, then the real service's status while it stops
    f.enqueue("/api/supervisor/stop",response(202,{stopping:true,mode:"drain"}));
    await h.$("supervisor-stop-btn").fire("click"); await h.$("supervisor-drain-btn").fire("click"); await h.waitForRequests();
    const stopping=realShapes().stopping.status; assert.equal(stopping.phase,"stopping","the real service no longer reports stopping");
    f.setSnapshot(stopping); await h.fireTimers();
    assert.doesNotMatch(h.$("supervisor-status").textContent,/not running/i); assert.match(h.$("supervisor-status").textContent,/stopping/i);
    assert.equal(h.ctx.__test.S.sup.ack,null,"the stop acknowledgement was not cleared by the stopping status");
    assert.doesNotMatch(h.$("supervisor-status").textContent,/acknowledged/i);
    assert.equal(h.$("supervisor-start-btn").disabled,true,"Start enabled while stopping"); assert.match(h.$("supervisor-start-btn").title,/stopping/i);
  });
  await check("Start is disabled while cards are stuck and no supervisor runs, with the banner text as the reason",async()=>{
    const stuckCard={number:4,title:"S",body:"",labels:[],comments:[],state:"ready",known:true,stuck:{kind:"merge_pending",detail:"x"},activity:null};
    const f=fakeFetch({notRunning:true,cards:[stuckCard,{...stuckCard,number:5}]}), h=make(f); await h.flush(); await h.waitForRequests();
    const b=h.$("supervisor-start-btn"); assert.equal(b.disabled,true,"Start enabled with stuck cards");
    assert.equal(b.title,"2 stuck cards — the supervisor will not start until they are resolved"); assert.ok(b.getAttribute("aria-describedby"));
    const g=fakeFetch({notRunning:true,cards:[{...stuckCard,stuck:null}]}), k=make(g); await k.flush(); await k.waitForRequests();
    assert.equal(k.$("supervisor-start-btn").disabled,false,"Start disabled with nothing stuck");
  });
  await check("the drill-down is fetched on open, not on every poll, and a failed refresh keeps the last render",async()=>{
    const cardUsage={card:4,totals:tok(5),columns:[{column:"in_progress",totals:tok(5),actions:[{action:"implement",role:"implementor",model:"opus",input:5,output:0,cache_read:0,cache_write:0,log:null}]}]};
    const f=fakeFetch({cardUsage}), h=make(f); await h.flush(); await h.waitForRequests();
    const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); await card.fire("click"); await h.waitForRequests();
    assert.equal(countCalls(f,"/api/cards/4/usage"),1);
    for(let i=0;i<3;i++) await h.fireTimers();
    assert.equal(countCalls(f,"/api/cards/4/usage"),1,"the drill-down was refetched by a poll");
    assert.ok(h.$("dr-usage-cols").textContent.includes("implement"));
    // a refresh that fails (the same card reopened) must not wipe a render that is showing
    const before=h.$("dr-usage-cols").textContent; f.enqueue("/api/cards/4/usage",response(500,{error:"x"}));
    await h.ctx.loadCardUsage(h.ctx.__test.S.drawer); await h.flush();
    assert.equal(h.$("dr-usage-cols").textContent,before,"a failed refresh dropped the last good render"); assert.equal(h.$("dr-usage-sec").hidden,false);
  });
  const tokSpans=h=>h.$("board").all().filter(n=>n.classList.contains("col-tokens"));
  const tokensOf=(h,key)=>h.$("board").all().find(n=>n.classList.contains("col")&&n.dataset.state===key).all().find(n=>n.classList.contains("col-tokens"));
  await check("column headers show the all-time token total of that column",async()=>{
    const cols={in_progress:tok(1234567),ready:tok(45,{unknown:1,partial:true}),backlog:undefined};
    delete cols.backlog;
    const f=fakeFetch({usage:{...usage,columns:cols}}), h=make(f); await h.flush(); await h.waitForRequests();
    const prog=tokensOf(h,"in_progress"); assert.equal(prog.textContent,"1.2M tokens"); assert.equal(prog.title,"1,234,567 tokens");
    const ready=tokensOf(h,"ready"); assert.equal(ready.textContent,"≥ 45 tokens"); assert.match(ready.title,/≥ 45.*some usage unknown/);
    assert.equal(tokensOf(h,"backlog").textContent,"","a column with no lines shows nothing, not 0");
    assert.doesNotMatch(h.$("board").textContent,/\$|\bUSD\b|\bcost\b/i);
    // an unreadable ledger shows no total at all, never 0
    const g=fakeFetch({usage:{run:null,all_time:null,planner:null,columns:cols,error:"usage ledger unreadable"}}), k=make(g); await k.flush(); await k.waitForRequests();
    for(const n of tokSpans(k)) assert.equal(n.textContent,"","an unreadable ledger showed "+n.textContent);
  });
  await check("a column total is text only, even for hostile names and values",async()=>{
    const x=fakeFetch({usage:{...usage,columns:{in_progress:tok(5),[hostile]:tok(5)}}}), y=make(x); await y.flush(); await y.waitForRequests();
    assert.ok(tokSpans(y).length>=3);
    for(const n of tokSpans(y)) assert.equal(n.children.length,0,"a column total span holds elements");
    assert.equal(tokensOf(y,"in_progress").textContent,"5 tokens");
  });
  await check("compact counts step to B at 999,950,000",async()=>{
    const cols={backlog:tok(999949999),ready:tok(999950000),in_progress:tok(999949),};
    const f=fakeFetch({usage:{...usage,all_time:tok(999949999+999950000+999949),columns:cols}}), h=make(f); await h.flush(); await h.waitForRequests();
    assert.equal(tokensOf(h,"backlog").textContent,"999.9M tokens"); assert.equal(tokensOf(h,"ready").textContent,"1B tokens");
    assert.equal(tokensOf(h,"in_progress").textContent,"999.9k tokens");
  });
  await check("a partial total reads as a lower bound with the unit; no readable count is unknown tokens",async()=>{
    const cols={in_progress:tok(1234567,{unknown:2,partial:true}),ready:tok(0,{unknown:1,partial:true})};
    const f=fakeFetch({usage:{...usage,all_time:tok(1234567),columns:cols}}), h=make(f); await h.flush(); await h.waitForRequests();
    assert.equal(tokensOf(h,"in_progress").textContent,"≥ 1.2M tokens");
    assert.equal(tokensOf(h,"ready").textContent,"unknown tokens"); assert.doesNotMatch(tokensOf(h,"ready").textContent,/≥ 0|^0/);
    assert.match(tokensOf(h,"ready").title,/unknown/i);
  });
  await check("a not-running status reply that is not due for a usage read supplies the columns",async()=>{
    const fromUsage={in_progress:tok(100)}, fromStatus={in_progress:tok(7000)};
    const f=fakeFetch({notRunning:{columns:fromStatus},usage:{run:null,all_time:tok(7000),planner:tok(7),columns:fromUsage}}), h=make(f); await h.flush(); await h.waitForRequests();
    assert.equal(tokensOf(h,"in_progress").textContent,"100 tokens"); assert.equal(countCalls(f,"/api/usage"),1);
    await h.fireTimers(); await h.waitForRequests();
    assert.equal(countCalls(f,"/api/usage"),1,"the poll was due for a usage read");
    assert.equal(tokensOf(h,"in_progress").textContent,"7k tokens","the not-running reply's columns were dropped");
  });
  await check("when /api/usage fails and nothing runs, the not-running reply's columns are shown",async()=>{
    const f=fakeFetch({notRunning:{columns:{in_progress:tok(7000)}}}); f.enqueue("/api/usage",response(500,{error:"x"}));
    const h=make(f); await h.flush(); await h.waitForRequests();
    assert.equal(countCalls(f,"/api/usage"),1);
    assert.equal(tokensOf(h,"in_progress").textContent,"7k tokens","the fallback dropped the columns");
  });
  await check("tokens in no page column are shown as the remainder of the all-time total",async()=>{
    // no unknown-state cards: the remainder goes in the All time tooltip
    const f=fakeFetch({cards:[],usage:{...usage,all_time:tok(1234),columns:{in_progress:tok(1000)}}}), h=make(f); await h.flush(); await h.waitForRequests();
    const all=h.$("supervisor-tokens").all().find(n=>/^All time/.test(n.textContent));
    assert.match(all.title,/234 tokens in columns no longer on the board/);
    const shown=tokSpans(h).map(n=>n.title).filter(Boolean).map(t=>Number(t.replace(/\D/g,"")));
    assert.equal(shown.reduce((a,b)=>a+b,0)+234,1234,"headers plus remainder do not equal all time");
    // with an Unknown state group, the remainder goes on its header
    const g=fakeFetch({usage:{...usage,all_time:tok(1234),columns:{in_progress:tok(1000),gone_stage:tok(200)}}}), k=make(g); await k.flush(); await k.waitForRequests();
    const unk=k.$("board").all().find(n=>n.classList.contains("col")&&n.classList.contains("unknown")).all().find(n=>n.classList.contains("col-tokens"));
    assert.equal(unk.textContent,"234 tokens"); assert.match(unk.title,/in columns no longer on the board/);
    const all2=k.$("supervisor-tokens").all().find(n=>/^All time/.test(n.textContent)); assert.ok(!all2.title,"the tooltip repeated a remainder shown on the group");
    // nothing left over, nothing shown
    const m=make(fakeFetch({cards:[],usage:{...usage,all_time:tok(1000),columns:{in_progress:tok(1000)}}})); await m.flush(); await m.waitForRequests();
    assert.ok(!m.$("supervisor-tokens").all().find(n=>/^All time/.test(n.textContent)).title);
  });
  await check("the collapsible toggle's accessible name leaves out the live total",async()=>{
    const f=fakeFetch({states:states.concat([{key:"done",name:"Done"}]),usage:{...usage,columns:{done:tok(1234567)}}}), h=make(f); await h.flush(); await h.waitForRequests();
    const toggles=h.$("board").all().filter(n=>n.classList.contains("col-toggle"));
    assert.equal(toggles.length,1,"no collapsible column to check");
    assert.equal(toggles[0].attrs["aria-label"],"Done"); assert.equal(tokensOf(h,"done").textContent,"1.2M tokens");
  });
  await check("a poll with unchanged totals does not rewrite column headers; a changed total does",async()=>{
    const f=fakeFetch({usage:{...usage,columns:{in_progress:tok(900)}}}), h=make(f); await h.flush(); await h.waitForRequests();
    const span=tokensOf(h,"in_progress"); assert.equal(span.textContent,"900 tokens");
    // count every write to the span, including a rewrite with the same value
    const writes={text:0,title:0};
    const find=(o,k)=>{ for(let p=o;p;p=Object.getPrototypeOf(p)){ const d=Object.getOwnPropertyDescriptor(p,k); if(d) return d; } };
    for(const [k,w] of [["textContent","text"],["title","title"]]){
      const d=find(span,k); let v=span[k];
      Object.defineProperty(span,k,{configurable:true,get(){ return d&&d.get?d.get.call(this):v; },set(x){ writes[w]++; if(d&&d.set) d.set.call(this,x); else v=x; }});
    }
    const list=h.$("cards-in_progress");
    h.ctx.__advanceClock(16000); await h.fireTimers(); await h.waitForRequests();
    assert.equal(countCalls(f,"/api/usage"),2); assert.equal(tokensOf(h,"in_progress"),span,"an unchanged total replaced the element");
    assert.deepEqual(writes,{text:0,title:0},"an unchanged total was written again");
    assert.equal(h.$("cards-in_progress"),list,"the card list was rebuilt by a usage poll");
    const fresh=json({...usage,columns:{in_progress:tok(2500)}}); f.enqueue("/api/usage",response(200,fresh));
    h.ctx.__advanceClock(16000); await h.fireTimers(); await h.waitForRequests();
    assert.equal(span.textContent,"2.5k tokens"); assert.ok(writes.text>=1);
  });
  await check("/api/usage is re-read at most every 15 seconds",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    assert.equal(countCalls(f,"/api/usage"),1);
    for(let i=0;i<4;i++) await h.fireTimers();
    assert.equal(countCalls(f,"/api/usage"),1,"usage re-read on every status poll");
    h.ctx.__advanceClock(16000); await h.fireTimers();
    assert.equal(countCalls(f,"/api/usage"),2,"usage never refreshed after 15 s");
    for(let i=0;i<2;i++) await h.fireTimers();
    assert.equal(countCalls(f,"/api/usage"),2);
  });
  // The "ignored by the running supervisor" banner case is gone with its branch: while a supervisor runs the
  // board carries no stuck findings (board-web.py stuck_view), so that banner could never show.
  await check("with no supervisor, Start waits for the stuck check and for a suppression to end",async()=>{
    const fine={number:6,title:"Fine",body:"",labels:[],comments:[],state:"ready",known:true,stuck:null,activity:null};
    const startOf=async run=>{ const f=fakeFetch({notRunning:true,cards:[fine],run:{state:"idle",stuck_error:null,stuck_suppressed:null,...run}}), h=make(f);
      await h.flush(); await h.waitForRequests(); return h.$("supervisor-start-btn"); };
    let b=await startOf({stuck_checking:true,stuck_known:false,stuck_checked_at:null});
    assert.equal(b.disabled,true,"Start enabled before the first stuck check"); assert.equal(b.title,"checking for stuck cards…"); assert.ok(b.getAttribute("aria-describedby"));
    b=await startOf({stuck_checking:false,stuck_known:false,stuck_checked_at:1794333510,stuck_error:"config.sh failed: boom"});
    assert.equal(b.disabled,true,"Start enabled when the only stuck check failed"); assert.match(b.title,/stuck check failed: config\.sh failed: boom/);
    b=await startOf({stuck_checking:true,stuck_known:true,stuck_checked_at:1794333510});
    assert.equal(b.disabled,false,"Start disabled while re-checking with a good result");
    b=await startOf({stuck_checking:false,stuck_known:true,stuck_checked_at:1794333510,stuck_error:"boom"});
    assert.equal(b.disabled,false,"a failed re-check hid the last good result");
    b=await startOf({stuck_checking:false,stuck_known:false,stuck_suppressed:"a run is active (pid 77)"});
    assert.equal(b.disabled,true,"Start enabled while a run holds the lock"); assert.equal(b.title,"a run is active (pid 77)");
  });
  await check("the Start acknowledgement waits for ready",async()=>{
    const f=fakeFetch({notRunning:true}), h=make(f); await h.flush(); await h.waitForRequests();
    f.enqueue("/api/supervisor/start",response(202,{command_id:"c1",state_revision:1,desired_mode:"running",phase:"starting",launched:true}));
    await h.$("supervisor-start-btn").fire("click"); await h.waitForRequests();
    assert.ok(h.ctx.__test.S.sup.ack,"no acknowledgement kept");
    // the startup check still runs: the service answers, its revision moved, but it is not ready
    const checking=response(200,{...json(snapshot),revision:3,ready:false,startup:"checking",running:true});
    f.enqueue("/api/supervisor",checking,checking); await h.fireTimers();
    assert.ok(h.ctx.__test.S.supervisor&&h.ctx.__test.S.supervisor.ready===false,"the not-ready status was not adopted");
    assert.ok(h.ctx.__test.S.sup.ack,"the Start acknowledgement was cleared before ready");
    assert.match(h.$("supervisor-status").textContent,/acknowledged/i);
    const ready=response(200,{...json(snapshot),revision:3,ready:true,startup:"done",running:true});
    f.enqueue("/api/supervisor",ready,ready,ready); await h.fireTimers(); await h.fireTimers();
    assert.equal(h.ctx.__test.S.sup.ack,null,"ready did not clear the acknowledgement");
  });
  await check("a hidden tab backs the board poll off and asks for no stuck refresh",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    const delays=[], orig=h.ctx.setTimeout;
    h.ctx.setTimeout=function(fn,ms){ if(fn===h.ctx.fetchBoard) delays.push(ms); return orig(fn,ms); };
    await h.setHidden(true); await h.fireTimers();
    const boards=()=>f.calls.filter(c=>c.url.split("?")[0]==="/api/board");
    assert.equal(boards().slice(-1)[0].url,"/api/board?refresh_stuck=0","a hidden poll did not ask for no stuck refresh");
    assert.ok(delays.length&&delays.every(ms=>ms>=30000),"the hidden board poll did not back off: "+JSON.stringify(delays));
    delays.length=0; await h.setHidden(false); await h.fireTimers();
    assert.equal(boards().slice(-1)[0].url,"/api/board","a visible poll asked for no refresh");
    assert.ok(delays.includes(3000),"the visible board poll did not resume at 3 s: "+JSON.stringify(delays));
  });
  await check("a card's elapsed time updates in place without re-rendering its column",async()=>{
    const card=e=>({number:6,title:"Busy",body:"",labels:[],comments:[],state:"ready",known:true,stuck:null,activity:{action:"review",elapsed_seconds:e}});
    const f=fakeFetch({cards:[card(61)]}), h=make(f); await h.flush(); await h.waitForRequests();
    const cardOf=()=>h.$("board").all().find(x=>x.classList.contains("card")&&x.dataset.n==="6");
    const before=cardOf(); assert.match(before.textContent,/1m 1s/);
    f.enqueue("/api/board",response(200,{repo:"acme/toy",states,cards:[card(64)],run:{state:"idle"}})); await h.fireTimers();
    assert.equal(cardOf(),before,"the column re-rendered for an elapsed-time change");
    assert.match(cardOf().textContent,/1m 4s/,"the elapsed time was not updated: "+cardOf().textContent);
    f.enqueue("/api/board",response(200,{repo:"acme/toy",states,cards:[{...card(64),activity:{action:"merge",elapsed_seconds:65}}],run:{state:"idle"}})); await h.fireTimers();
    assert.notEqual(cardOf(),before,"a changed action did not re-render"); assert.match(cardOf().textContent,/merge/);
  });
  // The failure summary is printed, never written: the suite leaves no file behind.
  if(failures.length) {
    console.log(failures.map(x=>"- "+x.name+": "+x.reason.split("\n")[0]).join("\n"));
    console.log("RED summary: "+failures.length+" supervisor UI checks fail"); process.exitCode=1;
  }
}
main().catch(error=>{console.error("not ok - supervisor UI harness setup: "+error.stack);process.exitCode=1;});
