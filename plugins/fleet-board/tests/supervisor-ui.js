"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const loadBoard = require("./supervisor-ui-harness");

const boardPath = path.join(__dirname, "../scripts/board-web/static/board.js");
const reportPath = path.join(__dirname, "../../../.superpowers/sdd/2026-11-07-persistent-supervisor/task-5.2-s3-tests-report.md");
const hostile = '<img src=x onerror="alert(1)">';
const control = "\u0001\u202e";
const states = [{key:"backlog",name:"Backlog"},{key:"ready",name:"Ready"},{key:"in_progress",name:"In Progress"}];
const baseCard = {number:4,title:hostile,body:"repair me",labels:[],comments:[],state:"bogus",known:false,
  activity:"launch",elapsed_seconds:61,heartbeat_age_seconds:8,progress_age_seconds:13,retry_count:2,
  wait_reason:hostile,blocking_card:9,blocking_path:"src/locked",reservation_state:"held",reservation_revision:5,
  logs:[{id:hostile,text:hostile}]};
const snapshot = {schema_version:1,revision:7,desired_mode:"running",observed_phase:"running",ready:true,
  heartbeat_at:"2026-11-10T18:00:00Z",global_capacity:4,occupancy:2,
  providers:{[hostile]:{occupied:1,capacity:2}},counts:{ready:2,running:1,waiting:3,attention:1},
  budget:{known_spend:1.25,unknown_spend:true,deadline:"2026-11-10T20:00:00Z"},
  boot_registration:{state:"missing"},last_error:hostile,cards:[baseCard]};
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
    const f=fakeFetch({snapshot:{...json(snapshot),occupancy:null}}), h=make(f); await h.flush(); await h.waitForRequests();
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
    f.setSnapshot({...json(snapshot),ready:true,observed_phase:"running"}); await h.fireTimers();
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
    f.enqueue("/api/supervisor/pause",response(409,{error:"revision conflict",snapshot:{...json(snapshot),revision:12,observed_phase:"paused"}}));
    await h.$("supervisor-pause-btn").fire("click"); await h.flush();
    assert.equal(h.ctx.__test.S.supervisor.revision,12,"409 state body not adopted");
    assert.match(h.$("supervisor-status").textContent,/paused/i,"409 state not rendered");
    assert.equal(countCalls(f,"/api/supervisor/pause","POST"),1,"409 resent command");
    f.enqueue("/api/supervisor/start",response(503,{reason:"maintenance window"}));
    await h.$("supervisor-start-btn").fire("click"); assert.match(h.document.body.textContent,/maintenance window/i,"503 reason absent");
    f.enqueue("/api/supervisor/start",response(400,{message:"invalid request"}));
    await h.$("supervisor-start-btn").fire("click"); assert.match(h.document.body.textContent,/invalid request/i,"400 message absent");
  });
  await check("3e. Allowed mode matrix enables only valid controls",async()=>{
    const paused={...json(snapshot),desired_mode:"paused",observed_phase:"paused",ready:true};
    const f=fakeFetch({snapshot:paused}), h=make(f); await h.flush(); await h.waitForRequests();
    assert.equal(h.$("supervisor-start-btn").disabled,true,"Start active while paused");
    assert.equal(h.$("supervisor-resume-btn").disabled,false,"Resume unavailable while paused");
    assert.equal(h.$("supervisor-pause-btn").disabled,true,"Pause available while paused");
    f.setSnapshot({...paused,desired_mode:"running",observed_phase:"running"}); await h.fireTimers();
    assert.equal(h.$("supervisor-pause-btn").disabled,false,"Pause unavailable while running");
    assert.equal(h.$("supervisor-resume-btn").disabled,true,"Resume active while running");
  });
  await check("4. Unreachable and failed polls preserve last snapshot and gate mutations",async()=>{
    const stale={...json(snapshot),unreachable:true,reason:"controller offline"};
    const f=fakeFetch({snapshot:stale}), h=make(f); await h.flush(); await h.waitForRequests(); const s=h.$("supervisor-status");
    assert.match(s.textContent,/occupancy unknown/i); assert.ok(s.textContent.includes(snapshot.heartbeat_at)); assert.ok(s.textContent.includes("controller offline"));
    for(const id of ["supervisor-start-btn","supervisor-pause-btn","supervisor-resume-btn","supervisor-stop-btn"]){
      const b=h.$(id); assert.equal(b.disabled,true,id+" enabled stale"); assert.ok(b.title||b.getAttribute("aria-describedby"),id+" lacks disabled explanation");
    }
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
    const intervalBefore=f.timers.length; await h.setHidden(true); assert.ok(f.timers.length>=intervalBefore,"hidden document stopped scheduling without backoff");
    const polls=countCalls(f,"/api/supervisor/events"); await h.fireTimers(); assert.ok(countCalls(f,"/api/supervisor/events")>=polls,"hidden polling stopped entirely");
    await h.setHidden(false); assert.ok(f.timers.length>0,"visible document did not resume polling");
  });
  await check("6. Drawer separates execution ages, reservation controls and audited resolutions",async()=>{
    const f=fakeFetch({execution:{...baseCard,paused:true,writer:false}}), h=make(f); await h.flush(); await h.waitForRequests();
    const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); assert.ok(card); await card.fire("click");
    for(const id of ["dr-activity","dr-elapsed","dr-heartbeat-age","dr-progress-age","dr-retry-count","dr-wait-reason","dr-reservation-state"])
      assert.ok(h.$(id).children.length||h.$(id).textContent,id+" missing separate execution detail");
    assert.ok(h.$("dr-wait-reason").textContent.includes(hostile)); assert.ok(h.$("dr-wait-reason").textContent.includes("9")); assert.ok(h.$("dr-wait-reason").textContent.includes("src/locked"));
    const release=h.$("dr-release-reservations"); assert.ok(release,"reservation release action missing"); assert.equal(release.disabled,false,"release disabled while paused with no writer"); await release.fire("click");
    const rc=f.calls.find(c=>c.url.includes("release-reservations")&&c.method==="POST"); assert.ok(rc); assert.equal(rc.body.expected_reservation_revision,5);
    for(const action of ["retry","record_usage","confirm_effect","abandon"]){
      const button=h.$("dr-resolve-"+action); assert.ok(button,"missing resolve "+action); await button.fire("click");
      const call=f.calls.find(c=>c.url.includes("/resolve")&&c.body&&c.body.action===action); assert.ok(call,"resolve POST missing "+action);
      assert.ok(call.body.reason&&call.body.evidence,"reason/evidence missing "+action); assert.ok(call.body.request_id&&call.body.expected_revision!==undefined,"audit envelope missing "+action);
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
      providers:{[hostile]:{occupied:1,capacity:2}},reasons:[hostile],evidence:[hostile],events:[{sequence:1,type:"launch",timestamp:"2026-11-10T17:59:00Z",payload:{reason:hostile,evidence:hostile}}]};
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
    const f=fakeFetch({snapshot:{...json(snapshot),unreachable:true}}), h=make(f); await h.flush(); await h.waitForRequests();
    const card=h.$("board").all().find(n=>n.classList.contains("card")&&n.dataset.n==="4"); assert.ok(card); assert.match(card.closest("section").textContent,/Unknown/i);
    assert.ok(h.$("board").textContent.includes("held"),"unknown card reservation hidden"); await card.fire("click");
    assert.equal(h.$("dr-save").disabled,true,"unknown state auto-normalized while stale"); assert.ok(h.$("dr-release-reservations"),"reservation detail absent");
  });
  await check("9. Keyboard, button semantics, focus order and accessible status",async()=>{
    const f=fakeFetch(), h=make(f); await h.flush(); await h.waitForRequests(); const status=h.$("supervisor-status");
    assert.equal(status.getAttribute("role"),"status"); assert.ok(status.getAttribute("aria-label")); assert.ok(status.getAttribute("aria-live"));
    const controls=["supervisor-start-btn","supervisor-pause-btn","supervisor-stop-btn"];
    for(const id of controls) assert.equal(h.$(id).tagName,"BUTTON",id+" is not a button");
    const ordered=controls.map(id=>h.$(id)).sort((a,b)=>(a.tabIndex||0)-(b.tabIndex||0));
    assert.equal(new Set(ordered.map(n=>n.tabIndex)).size,ordered.length,"controls lack navigable tab order");
    const stop=h.$("supervisor-stop-btn"); await stop.fire("click"); const menu=h.$("supervisor-stop-menu");
    const first=menu.children[0]; const key=await h.key(first,"ArrowDown"); assert.ok(key.defaultPrevented,"arrow navigation not handled");
    const enter=await h.key(first,"Enter"); assert.ok(enter.defaultPrevented,"Enter not handled");
    await stop.fire("click"); const space=await h.key(stop," "); assert.ok(space.defaultPrevented,"Space not handled");
    for(const b of [h.$("supervisor-pause-btn"),h.$("supervisor-resume-btn")]) if(b.disabled) assert.ok(b.title||b.getAttribute("aria-describedby"),"disabled explanation inaccessible");
  });
  if(failures.length) {
    const report=failures.map(x=>"- "+x.name+": "+x.reason.split("\n")[0]).join("\n");
    require("fs").writeFileSync(reportPath,"# Task 5.2 S3 failing checks\n\n"+report+"\n");
    console.log("RED summary: "+failures.length+" supervisor UI checks fail"); process.exitCode=1;
  } else {
    require("fs").writeFileSync(reportPath,"# Task 5.2 S3 failing checks\n\nNo failing checks.\n");
  }
}
main().catch(error=>{console.error("not ok - supervisor UI harness setup: "+error.stack);process.exitCode=1;});
