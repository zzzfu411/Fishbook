// Deterministic lifecycle ordering checks, using the exact controller shipped in HTML.
// No browser UI or user data is read or written.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const source = fs.readFileSync(path.join(__dirname, '../Sources/MarkdownView.swift'), 'utf8');
const match = source.match(/static let restorationScript = #"""([\s\S]*?)"""#/);
assert(match, 'the shipped restoration controller must be available');
const context = {};
vm.createContext(context);
vm.runInContext(match[1], context);
const make = context.makeReaderRestoreController;
const saved = 0.326128515;
const geometry = {width: 480, height: 600, extent: 40_000, y: 0, contentReady: true, now: 0};

// Cold startup: load may precede attachment and a usable WKWebView viewport.
const cold = make(saved);
let result = cold.sample({...geometry, width: 0, height: 0});
assert(!result.ready && result.pending && result.target === null, 'zero frame must not complete or save zero');
result = cold.sample({...geometry, now: 80});
assert.equal(result.target, saved * geometry.extent, 'attachment requests the saved offset');
// WebKit ignoring an early scroll must cause retry, not a false ready state.
result = cold.sample({...geometry, now: 160});
assert.equal(result.target, saved * geometry.extent);
assert(!result.ready);
const initialTarget = saved * geometry.extent;
result = cold.sample({...geometry, y: initialTarget, now: 240});
assert(!result.ready, 'a single correct frame is not settled');
// A later native layout changes document geometry and cancels the early position.
result = cold.sample({...geometry, extent: 42_000, y: 0, now: 400});
assert.equal(result.target, saved * 42_000);
result = cold.sample({...geometry, extent: 42_000, y: saved * 42_000, now: 480});
assert(!result.ready);
result = cold.sample({...geometry, extent: 42_000, y: saved * 42_000, now: 1040});
assert(result.ready && !result.pending, 'only an observed stable target is ready');

// Late appearance/geometry changes recheck the intended progress before user control.
cold.recheck();
result = cold.sample({...geometry, extent: 46_000, y: saved * 42_000, now: 1200});
assert.equal(result.target, saved * 46_000);
assert(!result.ready);

// User takes over during pending restore: further timers/resizes must never pull back.
cold.cancel();
cold.recheck();
result = cold.sample({...geometry, y: 900, now: 2000});
assert(cold.userControlled() && result.ready && !result.pending && result.target === null);
result = cold.sample({...geometry, extent: 90_000, y: 4000, now: 10000});
assert.equal(result.target, null);

// Fonts/images not ready cannot accidentally report a temporary top position.
const delayed = make(saved);
result = delayed.sample({...geometry, contentReady: false, now: 10_000});
assert(!result.ready && result.target === null);
delayed.cancel();
result = delayed.sample({...geometry, contentReady: false, now: 10_100});
assert(!result.ready && result.target === null);
result = delayed.sample({...geometry, contentReady: true, y: 800, now: 10_200});
assert(result.ready && result.target === null, 'user position survives completion of loading');

// A short document and invalid progress do not create infinite restore loops.
const short = make(Number.NaN);
assert(!short.sample({...geometry, extent: 0, now: 0}).ready);
assert(short.sample({...geometry, extent: 0, now: 560}).ready);
assert.equal(make(9).sample({...geometry}).target, geometry.extent);
assert.equal(make(-1).sample({...geometry, y: 500}).target, 0);
// Paragraph-relative positions survive inserted content and reflow at a new font.
const resolve = context.resolveReaderLocation;
const semantic = {blockID:'same-paragraph',quote:'A stable research paragraph.',blockOffset:.35,progress:.44};
const oldBlocks = [{id:'same-paragraph',text:semantic.quote,top:2000,height:400}];
let resolved = resolve(semantic,oldBlocks,6000,40);
assert.equal(resolved.target,2100);
const revised = [{id:'new-introduction',text:'New preface.',top:0,height:900},
  {id:'same-paragraph',text:semantic.quote,top:4100,height:800}];
resolved = resolve(semantic,revised,10000,40);
assert.equal(resolved.target,4340,'position follows the same paragraph and within-paragraph fraction, not old global progress');
assert(resolved.exact && resolved.matchedBy==='block');
resolved = resolve({...semantic,blockID:'changed-format'},revised,10000,40);
assert(resolved.exact && resolved.matchedBy==='quote','unique unchanged excerpt can recover an edited block ID');
resolved = resolve({...semantic,blockID:'missing'},[...revised,{id:'duplicate',text:semantic.quote,top:7000,height:800}],10000,40);
assert(!resolved.exact && resolved.target===4400,'ambiguous excerpts must explicitly fall back, never guess');
resolved = resolve({...semantic,blockID:'missing',quote:'deleted'},revised,10000,40);
assert(!resolved.exact && resolved.matchedBy==='progress');
const semanticRestore=make(.44,semantic);
result=semanticRestore.sample({...geometry,blocks:revised,inset:40,extent:10000});
assert.equal(result.target,4340);
result=semanticRestore.sample({...geometry,blocks:revised,inset:40,extent:10000,y:4340,now:100});
assert(!result.ready);
result=semanticRestore.sample({...geometry,blocks:revised,inset:40,extent:10000,y:4340,now:700});
assert(result.ready);
semanticRestore.cancel();
result=semanticRestore.sample({...geometry,blocks:revised,inset:40,extent:15000,y:900,now:800});
assert.equal(result.target,null,'manual reading still takes priority over semantic restoration');

const history=context.makeReaderHistory(3);
const spot=n=>({blockID:'p'+n,blockOffset:0,progress:n/10});
history.remember(spot(1));history.remember(spot(2));history.remember(spot(3));
assert.equal(history.back(spot(4)).blockID,'p3');
assert.equal(history.back(spot(3)).blockID,'p2');
assert.equal(history.forward(spot(2)).blockID,'p3');
history.remember(spot(3));
assert(!history.state().canForward,'new navigation invalidates the forward branch');
history.remember(spot(4));history.remember(spot(5));history.remember(spot(6));
assert.equal(history.back(spot(7)).blockID,'p6');
assert.equal(history.back(spot(6)).blockID,'p5');
assert.equal(history.back(spot(5)).blockID,'p4');
assert.equal(history.back(spot(4)),null,'history is bounded');
console.log('PASS: cold viewport and late layout; user takeover; semantic restore after insertion and font reflow; unique quote fallback; ambiguous/deleted block detection; bounded multi-step back/forward history.');
