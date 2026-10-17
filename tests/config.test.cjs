// Tests the complete embedded program, with disk IO confined to a temporary fixture.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {EventEmitter} = require('node:events');
const source = fs.readFileSync(path.join(__dirname,'../scripts/repair.ps1'),'utf8');
const program = source.match(/\$program = @'\r?\n([\s\S]*?)\r?\n'@/)[1];

function fixture(t, {missing=false, collision=false}={}) {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'bridge 中文 '));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const resources=path.join(root,'app resources'), local=path.join(root,'local');
  const home=path.join(root,collision?'Codex':'home');
  fs.mkdirSync(home,{recursive:true});
  const run=path.join(root,'run');
  const host='com.openai.test', plugin=path.join(resources,'plugins/openai-bundled/plugins/chrome');
  const write=(p,bytes)=>{fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,bytes);};
  write(path.join(plugin,'scripts/extension-ids.json'),JSON.stringify({extensionHostName:host,extensionIds:['extension'],browserExtensions:[]}));
  write(path.join(plugin,'.codex-plugin/plugin.json'),JSON.stringify({version:'1.0.0'}));
  for(const rel of ['scripts/browser-client.mjs','scripts/browser-service.mjs','extension-host/windows/x64/extension-host.exe'])write(path.join(plugin,rel),'fixture');
  for(const rel of ['codex.exe','cua_node/bin/node.exe','cua_node/bin/node_repl.exe'])write(path.join(resources,rel),'fixture');
  fs.mkdirSync(path.join(resources,'cua_node/bin/node_modules'),{recursive:true});
  const targets=[path.join(local,'OpenAI/Codex/chrome-native-hosts-v2.json'),path.join(home,'chrome-native-hosts-v2.json'),path.join(local,'OpenAI/extension',host+'.json')];
  const original=targets.map((_,i)=>Buffer.from(i<2?' {"schemaVersion":2,"entries":[]}\r\n':'original manifest\r\n'));
  if(!missing)targets.forEach((p,i)=>write(p,original[i]));
  const logs=[];
  function execute(fail) {
    let renames=0, writes=0;
    const wrapped=new Proxy(fs,{get(target,key){
      if(key==='renameSync')return (from,to)=>{renames++;if(fail?.('rename',renames,from,to))throw Error('injected rename '+renames);return fs.renameSync(from,to);};
      if(key==='writeFileSync')return (p,...args)=>{writes++;if(fail?.('write',writes,p))throw Error('injected write '+writes);return fs.writeFileSync(p,...args);};
      return target[key];
    }});
    let handshakes=0;
    const spawn=()=>{
      const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();
      child.stdin=new EventEmitter();child.stdin.end=()=>{};child.kill=()=>{};
      child.stdin.write=frame=>{
        const request=JSON.parse(frame.subarray(4));handshakes++;
        const body=Buffer.from(JSON.stringify({id:request.id,result:{}})), head=Buffer.alloc(4);head.writeUInt32LE(body.length);
        child.stdout.emit('data',Buffer.concat([head,body]));
      };return child;
    };
    vm.runInNewContext(program,{
      require:name=>name==='fs'?wrapped:name==='child_process'?{spawn}:require(name),
      process:{argv:['node','repair.cjs',resources,home,'123','2026-10-17T00:00:00Z','TestFamily',run],env:{LOCALAPPDATA:local}},
      Buffer, console:{log:x=>logs.push(x),error:x=>logs.push(x)},setTimeout:()=>1,clearTimeout:()=>{}
    },{filename:'embedded-repair.cjs'});
    assert.equal(handshakes,2);
  }
  function restored() {
    targets.forEach((p,i)=>missing?assert.equal(fs.existsSync(p),false):assert.deepEqual(fs.readFileSync(p),original[i]));
    const temps=fs.readdirSync(root,{recursive:true}).filter(p=>p.includes('.tmp-'));
    assert.deepEqual(temps,[]);
  }
  return {root,targets,original,run,execute,restored,logs};
}

test('normal repair and repeated execution preserve unrelated entries and avoid duplicates',t=>{
  const f=fixture(t);
  const unrelated={entryId:'unrelated',nativeHostNames:['other']};
  fs.writeFileSync(f.targets[0],JSON.stringify({schemaVersion:2,entries:[unrelated]}));
  f.execute();f.execute();
  const first=JSON.parse(fs.readFileSync(f.targets[0]));
  assert.equal(first.entries.length,2);assert.deepEqual(first.entries[0],unrelated);
  assert.equal(JSON.parse(fs.readFileSync(f.targets[1])).entries.length,1);
  assert.equal(JSON.parse(fs.readFileSync(f.targets[2])).type,'stdio');
  assert.equal(fs.readdirSync(path.join(f.run,'backups')).length,2);
});
for(const missing of [false,true])for(const at of [1,2,3])test(`commit rename ${at} fails, initially ${missing?'absent':'present'}`,t=>{
  const f=fixture(t,{missing});
  assert.throws(()=>f.execute((op,n)=>op==='rename'&&n===at),/original files restored/);
  f.restored();
});
test('staging write failure leaves every original byte intact',t=>{
  const f=fixture(t);
  assert.throws(()=>f.execute((op,n,p)=>op==='write'&&p.startsWith(f.targets[1]+'.tmp-')),/original files restored/);
  f.restored();
});
test('backup failure occurs before commit',t=>{
  const f=fixture(t);
  assert.throws(()=>f.execute((op,n,p)=>op==='write'&&p.endsWith('1.bin')),/original files restored/);
  f.restored();
});
test('same parent basename has separate backup files',t=>{
  const f=fixture(t,{collision:true});
  f.execute();
  const backup=path.join(f.run,'backups',fs.readdirSync(path.join(f.run,'backups'))[0]);
  f.original.forEach((bytes,i)=>assert.deepEqual(fs.readFileSync(path.join(backup,i+'.bin')),bytes));
});
test('rollback failure is reported and other files still restore; backup survives',t=>{
  const f=fixture(t);
  assert.throws(()=>f.execute((op,n)=>op==='rename'&&(n===3||n===4)),/rollback incomplete.*backup:/);
  assert.deepEqual(fs.readFileSync(f.targets[0]),f.original[0]);
  const backup=path.join(f.run,'backups',fs.readdirSync(path.join(f.run,'backups'))[0]);
  assert.deepEqual(fs.readFileSync(path.join(backup,'1.bin')),f.original[1]);
});
test('unknown schema refuses modification',t=>{
  const f=fixture(t);fs.writeFileSync(f.targets[0],'{"schemaVersion":99,"entries":[]}');
  const before=f.targets.map(p=>fs.readFileSync(p));
  assert.throws(()=>f.execute(),/Unexpected existing native manifest schema/);
  f.targets.forEach((p,i)=>assert.deepEqual(fs.readFileSync(p),before[i]));
});
