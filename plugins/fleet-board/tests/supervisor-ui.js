"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const loadBoard = require("./supervisor-ui-harness");

const boardPath = path.join(__dirname, "../scripts/board-web/static/board.js");
const hostile = '<img src=x onerror="alert(1)">';
const control = "\u0001\u202e";
const states = [{key:"backlog",name:"Backlog"},{key:"ready",name:"Ready"},{key:"in_progress",name:"In Progress"}];
const baseCard = {number:4,title:hostile,body:"repair me",labels:[],comments:[],state:"bogus",known:false,
  activity:"launch",elapsed_seconds:61,heartbeat_age_seconds:8,progress_age_seconds:13,retry_count:2,
  wait_reason:hostile,blocking_card:9,blocking_path:"src/locked",reservation_state:"held",reservation_revision:5,
  logs:[{id:hostile,text:hostile}]};
const snapshot = {schema_version:1,revision:7,desired_mode:"running",phase:"running",ready:true,read_only:false,
  execution_available:true,host_boot_id:"boot-1",shutdown:"resolved",
  heartbeat:{at:"2026-11-10T18:00:00Z",age:3,fresh:true},
  session:{active:{id:"s1"},known_spend:1.25,unknown_spend:true,deadline:"2026-11-10T20:00:00Z"},
  capacity:{slots:2,global_cap:4,per_provider:{[hostile]:1}},
  queue:{ready:2,running:1,waiting:3,attention:1},
  config:{enabled:true,execution_available:true},
  boot_registration:"missing",last_error:hostile,claims:{count:2},cards:[baseCard]};
// What board-web serves when the service does not answer: the same top-level keys as
// null/unknown, the flag, and the last status it saw.
const unreachableOf = (known, extra) => ({schema_version:null,revision:null,desired_mode:null,phase:null,ready:null,
  read_only:true,execution_available:false,host_boot_id:null,shutdown:null,heartbeat:null,session:null,capacity:null,
  queue:null,config:null,boot_registration:null,last_error:null,claims:null,unreachable:true,last_known:json(known),
  last_known_at:Date.parse("2026-11-10T18:00:00Z")/1000,occupancy:null,cards:known.cards,...(extra||{})});
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
    if(url==="/api/board") return response(200,{repo:"acme/toy",states,cards:current.cards||[],run:{state:"idle"}});
    if(url==="/api/supervisor") return options.supervisor===false?response(404,{error:"missing"}):response(200,current);
    if(url==="/api/run") return response(200,{state:"idle"});
    if(url.startsWith("/api/supervisor/events?")) return response(200,{events:[],next_cursor:0});
    if(url==="/api/cards/4"&&method==="GET") return response(200,current.cards[0]);
    if(url==="/api/cards/4/execution") return response(200,options.execution||{});
    if(url==="/api/cards/4/move") return response(200,current.cards[0]);
    return response(404,{error:"unexpected fake route"});
  }
  function setSnapshot(value){current=json(value);}
  return {fetch,calls,enqueue,setSnapshot,get snapshot(){return current;}};
}
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
  await check("1b. Legacy 404 keeps legacy controls and polling read-only",async()=>{
    const f=fakeFetch({supervisor:false}), h=make(f); await h.flush(); await h.waitForRequests();
    assert.ok(countCalls(f,"/api/run")>=1,"legacy run poll absent");
    assert.equal(h.$("start-btn").hidden,false,"legacy Start hidden"); assert.equal(h.$("stop-btn").hidden,false,"legacy Stop hidden");
    assert.equal(f.calls.filter(c=>c.method==="POST").length,0,"legacy mode issued mutation during poll");
  });
  await check("2. Status exposes all snapshot fields and truthful boot/occupancy",async()=>{
    const s=ui.$("supervisor-status"), t=s.textContent;
    for(const value of ["running","ready","4","local","2","3","attention","1.25","unknown","20:00","missing",hostile])
      assert.ok(t.includes(value),"status missing snapshot field "+value);
    assert.doesNotMatch(t,/recovered after reboot|boot recovery/i,"unverified reboot recovery claim");
    const f=fakeFetch({snapshot:{...json(snapshot),capacity:{...snapshot.capacity,slots:null}}}), h=make(f); await h.flush(); await h.waitForRequests();
    assert.match(h.$("supervisor-status").textContent,/occupancy unknown/i,"null occupancy rendered as zero/omitted");
  });
  await check("3a. Start click sends revision-bound command and waits for ready poll",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
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
    f.enqueue("/api/supervisor/start",response(503,{reason:"maintenance window"}));
    await h.$("supervisor-start-btn").fire("click"); assert.match(h.document.body.textContent,/maintenance window/i,"503 reason absent");
    f.enqueue("/api/supervisor/start",response(400,{message:"invalid request"}));
    await h.$("supervisor-start-btn").fire("click"); assert.match(h.document.body.textContent,/invalid request/i,"400 message absent");
  });
  await check("3e. Allowed mode matrix enables only valid controls",async()=>{
    const paused={...json(snapshot),desired_mode:"paused",phase:"stopped",ready:true};
    const f=fakeFetch({snapshot:paused}), h=make(f); await h.flush(); await h.waitForRequests();
    assert.equal(h.$("supervisor-start-btn").disabled,true,"Start active while paused");
    assert.equal(h.$("supervisor-resume-btn").disabled,false,"Resume unavailable while paused");
    assert.equal(h.$("supervisor-pause-btn").disabled,true,"Pause available while paused");
    f.setSnapshot({...paused,desired_mode:"running",phase:"running"}); await h.fireTimers();
    assert.equal(h.$("supervisor-pause-btn").disabled,false,"Pause unavailable while running");
    assert.equal(h.$("supervisor-resume-btn").disabled,true,"Resume active while running");
  });
  await check("4. Unreachable and failed polls preserve last snapshot and gate mutations",async()=>{
    const stale=unreachableOf(snapshot,{reason:"controller offline"});
    const f=fakeFetch({snapshot:stale}), h=make(f); await h.flush(); await h.waitForRequests(); const s=h.$("supervisor-status");
    assert.match(s.textContent,/occupancy unknown/i); assert.ok(s.textContent.includes("2026-11-10 18:00:00")); assert.ok(s.textContent.includes("controller offline"));
    for(const id of ["supervisor-pause-btn","supervisor-resume-btn","supervisor-stop-btn"]){
      const b=h.$(id); assert.equal(b.disabled,true,id+" enabled stale"); assert.ok(b.title||b.getAttribute("aria-describedby"),id+" lacks disabled explanation");
    }
    assert.equal(h.$("supervisor-start-btn").disabled,false,"Start must stay enabled when the supervisor is unreachable: it launches the service");
    assert.equal(h.$("supervisor-retry-btn").disabled,false,"retry connection not live");
    const prior=h.ctx.__test.S.supervisor; f.setSnapshot({...json(snapshot),unreachable:false,revision:8}); await h.fireTimers();
    assert.notEqual(h.ctx.__test.S.supervisor,prior,"recovery poll did not replace snapshot"); assert.equal(h.$("supervisor-pause-btn").disabled,false);
    f.enqueue("/api/supervisor",new Error("network down")); await h.fireTimers();
    assert.match(h.$("supervisor-status").textContent,/occupancy unknown/i,"failed poll did not mark stale");
  });
  await check("5a. Event cursor pages, de-duplication, ordering and snapshot recovery",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    let eventUrl=f.calls.find(c=>c.url.startsWith("/api/supervisor/events?"));
    assert.ok(eventUrl,"event endpoint not polled"); assert.match(eventUrl.url,/after=0&limit=\d+/);
    const limit=Number(eventUrl.url.match(/limit=(\d+)/)[1]); assert.ok(limit>0&&limit<=500,"event limit unbounded");
    f.enqueue("/api/supervisor/events?after=0&limit="+limit,response(200,{events:[{sequence:2,type:"completion",timestamp:"2026-11-10T17:59:00Z",payload:{title:hostile}},{sequence:1,type:"launch",timestamp:"2026-11-10T17:58:00Z",payload:{title:hostile}}],next_cursor:2}));
    await h.fireTimers(); const timeline=h.$("supervisor-timeline"); assert.ok(timeline,"timeline element absent");
    assert.ok(timeline.textContent.includes("launch")&&timeline.textContent.includes("completion"),"event types omitted");
    const rows=timeline.children.map(n=>n.textContent); assert.ok(rows.length>=2,"events not rendered");
    const before=timeline.children.length; f.enqueue("/api/supervisor/events?after=2&limit="+limit,response(200,{events:[{sequence:2,type:"completion",timestamp:"2026-11-10T17:59:00Z"}],next_cursor:2})); await h.fireTimers();
    assert.equal(timeline.children.length,before,"duplicate sequence rendered twice");
    f.enqueue("/api/supervisor/events?after=2&limit="+limit,response(200,{events:[{sequence:4,type:"retry",timestamp:"2026-11-10T17:59:02Z"},{sequence:3,type:"launch",timestamp:"2026-11-10T17:59:01Z"}],next_cursor:4})); await h.fireTimers();
    const sorted=timeline.children.map(n=>n.textContent).join("|"); assert.ok(sorted.indexOf("launch")<sorted.lastIndexOf("retry"),"out-of-order event page was not sorted");
    await h.setHidden(true); await h.setHidden(false);
    f.enqueue("/api/supervisor/events?after=4&limit="+limit,response(200,{events:[{sequence:4,type:"retry",timestamp:"2026-11-10T17:59:02Z"}],next_cursor:4})); await h.fireTimers();
    assert.equal(timeline.children.length,before+2,"reconnect replay duplicated event rows");
    f.enqueue("/api/supervisor/events?after=2&limit="+limit,response(200,{snapshot_required:true,events:[],next_cursor:0})); await h.fireTimers();
    assert.ok(f.calls.filter(c=>c.url==="/api/supervisor").length>=2,"snapshot_required did not refetch full snapshot");
    assert.ok(f.calls.filter(c=>c.url==="/api/board").length>=2,"snapshot_required did not reload board");
    assert.ok(f.calls.some(c=>c.url.includes("events?after=0")),"cursor did not reset");
    assert.equal(f.calls.filter(c=>c.method==="POST").length,0,"event replay issued command");
  });
  await check("5b. Visibility backs polling off and resumes; timeline dates and ages use timestamps",async()=>{
    const f=fakeFetch(), h=make(f,{now:Date.parse("2026-11-10T18:00:00Z")}); await h.flush(); await h.waitForRequests();
    const eventCall=f.calls.find(c=>c.url.startsWith("/api/supervisor/events?")); const limit=Number(eventCall.url.match(/limit=(\d+)/)[1]);
    f.enqueue("/api/supervisor/events?after=0&limit="+limit,response(200,{events:[
      ...["launch","completion","retry","cancellation","release_override","recovery","control_action"].map((type,i)=>({sequence:i+1,type,timestamp:`2026-11-10T17:59:${String(i).padStart(2,"0")}Z`,message:"log says year 1900"}))
    ],next_cursor:7})); await h.fireTimers();
    const timeline=h.$("supervisor-timeline");
    for(const type of ["launch","completion","retry","cancellation","release_override","recovery","control_action"]) assert.ok(timeline.textContent.includes(type),"timeline omitted "+type);
    assert.match(timeline.textContent,/2026|59 seconds|1 minute/i,"structured event timestamp/age missing");
    const intervalBefore=h.timers.length; await h.setHidden(true); assert.ok(h.timers.length>=intervalBefore,"hidden document stopped scheduling without backoff");
    const polls=countCalls(f,"/api/supervisor/events"); await h.fireTimers(); assert.ok(countCalls(f,"/api/supervisor/events")>=polls,"hidden polling stopped entirely");
    await h.setHidden(false); assert.ok(h.timers.length>0,"visible document did not resume polling");
  });
  await check("6. Drawer separates execution ages, reservation controls and audited resolutions",async()=>{
    const f=fakeFetch({execution:{...baseCard,paused:true,writer:false}}), h=make(f); await h.flush(); await h.waitForRequests();
    const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); assert.ok(card); await card.fire("click");
    for(const id of ["dr-activity","dr-elapsed","dr-heartbeat-age","dr-progress-age","dr-retry-count","dr-wait-reason","dr-reservation-state"])
      assert.ok(h.$(id).children.length||h.$(id).textContent,id+" missing separate execution detail");
    assert.ok(h.$("dr-wait-reason").textContent.includes(hostile)); assert.ok(h.$("dr-wait-reason").textContent.includes("9")); assert.ok(h.$("dr-wait-reason").textContent.includes("src/locked"));
    h.$("dr-resolve-reason").value="paused for reconciliation"; const release=h.$("dr-release-reservations"); assert.ok(release,"reservation release action missing"); assert.equal(release.disabled,false,"release disabled while paused with no writer"); await release.fire("click");
    const rc=f.calls.find(c=>c.url.includes("release-reservations")&&c.method==="POST"); assert.ok(rc); assert.equal(rc.body.expected_reservation_revision,5);
    for(const action of ["retry","record_usage","confirm_effect","abandon"]){
      const button=h.$("dr-resolve-"+action); assert.ok(button,"missing resolve "+action);
      const before=f.calls.length; h.$("dr-resolve-reason").value=""; h.$("dr-resolve-evidence").value="";
      await button.fire("click");
      assert.equal(f.calls.slice(before).some(c=>c.url.includes("/resolve")),false,"resolve sent with an empty reason: the UI must not invent an audit reason");
      assert.match(h.document.body.textContent,/reason/i,"empty reason gave no feedback");
      h.$("dr-resolve-reason").value="verified by operator for "+action; h.$("dr-resolve-evidence").value="attempt-1\nlog-2";
      await button.fire("click");
      const call=f.calls.find(c=>c.url.includes("/resolve")&&c.body&&c.body.action===action); assert.ok(call,"resolve POST missing "+action);
      assert.equal(call.body.reason,"verified by operator for "+action); assert.deepEqual(call.body.evidence,["attempt-1","log-2"]); assert.ok(call.body.request_id&&call.body.expected_revision!==undefined,"audit envelope missing "+action);
    }
    f.enqueue("/api/cards/4/execution",response(400,{message:"resolution rejected"}));
    await h.$("dr-resolve-retry").fire("click"); assert.match(h.document.body.textContent,/resolution rejected/);
    f.enqueue("/api/cards/4/execution",response(409,{message:"execution revision conflict",execution:{...baseCard,revision:9}}));
    await h.$("dr-resolve-record_usage").fire("click"); assert.match(h.document.body.textContent,/execution revision conflict/);
    const log=h.$("dr-logs"); assert.ok(log.textContent.includes(hostile),"log content absent");
  });
  await check("6b. Reservation release stays disabled with an active writer",async()=>{
    const f=fakeFetch({execution:{...baseCard,paused:true,writer:true}}), h=make(f); await h.flush(); await h.waitForRequests();
    const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); await card.fire("click");
    assert.equal(h.$("dr-release-reservations").disabled,true,"release enabled with writer");
  });
  await check("7. Hostile server values remain text throughout UI fields and event payloads",async()=>{
    const bad={...json(snapshot),last_error:hostile+control,cards:[{...baseCard,title:hostile+control,wait_reason:hostile,logs:[{id:hostile,text:hostile}]}],
      capacity:{...snapshot.capacity,per_provider:{[hostile]:1}},reasons:[hostile],evidence:[hostile],events:[{sequence:1,type:"launch",timestamp:"2026-11-10T17:59:00Z",payload:{reason:hostile,evidence:hostile}}]};
    const f=fakeFetch({snapshot:bad}), h=make(f); await h.flush(); await h.waitForRequests();
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
  await check("8b. Unknown card repair and reservations remain visible while unreachable",async()=>{
    const f=fakeFetch({snapshot:unreachableOf(snapshot)}), h=make(f); await h.flush(); await h.waitForRequests();
    const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); assert.ok(card); assert.match(card.closest("section").textContent,/Unknown/i);
    assert.ok(h.$("board").textContent.includes("held"),"unknown card reservation hidden"); await card.fire("click");
    assert.equal(h.$("dr-save").disabled,true,"unknown state auto-normalized while stale"); assert.ok(h.$("dr-release-reservations"),"reservation detail absent");
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
    assert.deepEqual(Object.keys(real).sort(),["paused","quarantined","writer"]);
    assert.ok(h0().pageHtml.includes('id="dr-attempts"'),"drawer has no attempt history list");
    const plain={number:4,title:"Real card",body:"x",labels:[],comments:[],state:"in_progress",known:true};
    const itemsOf=h=>{ const m={}; for(const n of descendants(h.$("supervisor-status")).filter(x=>x.classList.contains("sup-item"))){
      const kids=n.children.map(c=>c.textContent); if(kids.length>=2) m[kids[0]]=kids.slice(1).join(" "); else m[""]=kids[0]||n.textContent; } return m; };
    const open=async scenario=>{ const r=real[scenario];
      const f=fakeFetch({snapshot:{...json(r.status),cards:[plain]},execution:json(r.execution)}), h=make(f); await h.flush(); await h.waitForRequests();
      const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); assert.ok(card,"card 4 not on the board");
      await card.fire("click"); await h.waitForRequests(); return h; };
    for(const scenario of ["paused","writer","quarantined"]) {
      const x=real[scenario].execution, h=await open(scenario), items=itemsOf(h), text=h.$("supervisor-status").textContent;
      assert.doesNotMatch(text,/unknown/i,scenario+": status bar shows unknown for a value the service knows: "+text);
      assert.match(items.slots||"",/^\d+ \/ 3$/,scenario+": slots not populated: "+JSON.stringify(items));
      for(const k of ["ready","running","waiting","attention"]) assert.match(String(items[k]),/^\d+$/,scenario+": queue "+k+" not populated");
      assert.match(items.budget||"",/\$1\.25 known/,scenario+": budget not populated");
      assert.match(items["boot registration"]||"",/^missing/,scenario+": boot registration not populated");
      assert.equal(items.desired,"stopped"); assert.equal(items.phase,"stopped");
      for(const id of ["dr-activity","dr-elapsed","dr-heartbeat-age","dr-progress-age","dr-retry-count","dr-reservation-state"]) {
        if(scenario==="writer"||id==="dr-retry-count"||id==="dr-activity"||id==="dr-reservation-state")
          assert.notEqual(h.$(id).textContent,"unknown",scenario+": "+id+" unknown for a value the service knows");
      }
      const paused=x.paused===true, writerFree=x.writer===false;
      assert.equal(h.$("dr-exec-resume").disabled,!paused,scenario+": Resume card must be enabled exactly when the real shape says paused");
      assert.equal(h.$("dr-exec-pause").disabled,paused,scenario+": Pause card must be enabled exactly when not paused");
      assert.equal(h.$("dr-release-reservations").disabled,!(paused&&writerFree),scenario+": Release reservations must be enabled exactly when paused with no writer");
    }
    let x=real.paused.execution,h=await open("paused");
    assert.equal(x.paused,true,"service does not report a paused card as paused"); assert.equal(x.writer,false,"service does not report writer=false"); assert.equal(x.reservation_state,"held");
    assert.equal(h.$("dr-release-reservations").disabled,false,"paused with no writer must allow release");
    assert.equal(h.$("dr-exec-resume").disabled,false,"paused card must allow resume");
    assert.match(h.$("dr-attempts").textContent,/no attempts/i);
    x=real.writer.execution; h=await open("writer");
    assert.equal(x.writer,true,"service does not report a live writer"); assert.equal(x.paused,false);
    assert.match(h.$("dr-activity").textContent,/running/);
    assert.ok(h.$("dr-attempts").textContent.includes("attempt-live")&&h.$("dr-attempts").textContent.includes("running"),"attempt history not rendered: "+h.$("dr-attempts").textContent);
    x=real.quarantined.execution; h=await open("quarantined");
    assert.equal(x.writer,true,"a quarantined attempt is an uncertain writer"); assert.match(h.$("dr-activity").textContent,/quarantined/);
    assert.ok(h.$("dr-attempts").textContent.includes("attempt-quarantined")&&h.$("dr-attempts").textContent.includes("quarantined"),"quarantined attempt not rendered");
  });
  await check("11a. Unreachable supervisor: Start launches it, other controls stay gated with reasons",async()=>{
    const f=fakeFetch({snapshot:unreachableOf(snapshot,{reason:"controller offline"})}), h=make(f); await h.flush(); await h.waitForRequests();
    assert.equal(h.$("supervisor-start-btn").disabled,false,"Start disabled while unreachable");
    for(const id of ["supervisor-pause-btn","supervisor-resume-btn","supervisor-stop-btn"]){
      const b=h.$(id); assert.equal(b.disabled,true,id+" enabled while unreachable"); assert.ok(b.title||b.getAttribute("aria-describedby"),id+" lacks a reason");
    }
    f.enqueue("/api/supervisor/start",response(202,{command_id:"c1",state_revision:8,desired_mode:"running",phase:"starting"}));
    await h.$("supervisor-start-btn").fire("click"); await h.waitForRequests();
    const call=f.calls.find(c=>c.url==="/api/supervisor/start"&&c.method==="POST");
    assert.ok(call,"Start click did not POST while unreachable"); assert.ok(call.body.request_id,"request id missing"); assert.equal(typeof call.body.expected_revision,"number","revision binding missing");
    f.setSnapshot({...json(snapshot),revision:8}); await h.fireTimers();
    assert.match(h.$("supervisor-status").textContent,/running/i,"launched service not rendered once it answers");
    assert.equal(h.$("supervisor-pause-btn").disabled,false,"Pause not available once running");
    // A board server that does not answer at all is a different failure: nothing can launch anything.
    const g=fakeFetch(), k=make(g); await k.flush(); await k.waitForRequests();
    g.enqueue("/api/supervisor",new Error("network down")); await k.fireTimers();
    assert.equal(k.$("supervisor-start-btn").disabled,true,"Start enabled although the board server does not answer");
  });
  await check("11b. Stop renders stopped (not a dead end), keeps Start enabled, and Start restarts",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    f.enqueue("/api/supervisor/stop",response(202,{command_id:"s1",state_revision:9,desired_mode:"stopped",phase:"stopped",status:"stopped",terminated:true}));
    await h.$("supervisor-stop-btn").fire("click"); await h.$("supervisor-drain-btn").fire("click"); await h.waitForRequests();
    // The service exits by design: the next poll finds nothing listening.
    f.setSnapshot(unreachableOf(snapshot,{reason:"connection refused"})); await h.fireTimers();
    const text=h.$("supervisor-status").textContent;
    assert.match(text,/stopped/i,"the board does not say stopped after Stop: "+text);
    assert.doesNotMatch(text,/unreachable|connection refused/i,"a requested Stop is shown as an error: "+text);
    assert.equal(h.$("supervisor-retry-btn").hidden,true,"Retry connection offered for a deliberate stop");
    assert.equal(h.$("supervisor-start-btn").disabled,false,"Start disabled after Stop");
    for(const id of ["supervisor-pause-btn","supervisor-resume-btn","supervisor-stop-btn"]) assert.equal(h.$(id).disabled,true,id+" enabled while stopped");
    f.enqueue("/api/supervisor/start",response(202,{command_id:"s2",state_revision:10,desired_mode:"running",phase:"starting"}));
    await h.$("supervisor-start-btn").fire("click"); await h.waitForRequests();
    assert.equal(countCalls(f,"/api/supervisor/start","POST"),1,"Start after Stop did not POST");
    f.setSnapshot({...json(snapshot),revision:10}); await h.fireTimers();
    assert.match(h.$("supervisor-status").textContent,/running/i,"restart not rendered");
    assert.doesNotMatch(h.$("supervisor-status").textContent,/unreachable/i);
    assert.equal(h.$("supervisor-pause-btn").disabled,false,"Pause not available after restart");
  });
  await check("11c. A stop that did not terminate the service is not shown as stopped",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests();
    f.enqueue("/api/supervisor/stop",response(202,{command_id:"s1",state_revision:9,desired_mode:"stopped",phase:"draining",status:"unresolved_shutdown",terminated:false}));
    await h.$("supervisor-stop-btn").fire("click"); await h.$("supervisor-drain-btn").fire("click"); await h.waitForRequests();
    f.setSnapshot(unreachableOf(snapshot,{reason:"connection refused"})); await h.fireTimers();
    assert.match(h.$("supervisor-status").textContent,/unreachable/i,"an unresolved shutdown was rendered as a clean stop");
  });
  await check("11d. A reloaded page whose board remembers the stop shows stopped with Start enabled",async()=>{
    const known={...json(snapshot),desired_mode:"stopped",phase:"stopped",ready:false};
    const f=fakeFetch({snapshot:unreachableOf(known,{reason:"connection refused"})}), h=make(f); await h.flush(); await h.waitForRequests();
    const text=h.$("supervisor-status").textContent;
    assert.doesNotMatch(text,/unreachable|connection refused/i,"remembered stop shown as an error: "+text);
    assert.match(text,/stopped/i); assert.equal(h.$("supervisor-start-btn").disabled,false);
  });
  await check("11e. The page says Start launches the service but does not run work yet",async()=>{
    const html=h0().pageHtml;
    assert.match(html,/id="supervisor-note"/,"no deferral note in the page");
    assert.match(html,/no scheduler is wired/i); assert.match(html,/execution is disabled by default/i); assert.match(html,/does not run (any )?work/i);
  });
  // The failure summary is printed, never written: the suite leaves no file behind.
  if(failures.length) {
    console.log(failures.map(x=>"- "+x.name+": "+x.reason.split("\n")[0]).join("\n"));
    console.log("RED summary: "+failures.length+" supervisor UI checks fail"); process.exitCode=1;
  }
}
main().catch(error=>{console.error("not ok - supervisor UI harness setup: "+error.stack);process.exitCode=1;});
