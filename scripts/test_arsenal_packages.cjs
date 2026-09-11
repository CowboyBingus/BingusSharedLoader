// Runs the installed manager backend against an isolated filesystem and profile.
// Usage: node scripts/test_arsenal_packages.cjs <Loader-ZIP> <Arsenal-source>
//        <new-output-directory> <Bounce-ZIP> <Steering-ZIP> [Reinforcement-ZIP]
// Arsenal-source must contain obfuscated_src/main and its node_modules.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const crypto = require('crypto');
const source = path.resolve(process.argv[3]);
const base = path.resolve(process.argv[4]);
fs.mkdirSync(base, {recursive: true});
const fixture = path.join(base, 'manager-fixture-' + crypto.randomUUID());
assert(!fs.existsSync(fixture), 'Fixture already exists; inspect before retrying.');
const fsExtra = require(path.join(source, 'node_modules/fs-extra'));
const extractZip = require(path.join(source, 'node_modules/extract-zip'));
const AdmZip = require(path.join(source, 'node_modules/adm-zip'));
const JSON5 = require(path.join(source, 'node_modules/json5'));
const game = path.join(fixture, 'Helldivers 2');
const data = path.join(game, 'data');
const library = path.join(fixture, 'library');
const temp = path.join(fixture, 'temp');
const state = path.join(fixture, 'state');
for (const folder of [data, path.join(game, 'bin'), library, temp, state]) fs.mkdirSync(folder, {recursive:true});
const records = {modsList:[], modsLibrary:[], userModsDir:library, userGameDir:game,
  selectedProfile:'test', dataPath:state, setModsActive:true, setAllOptionsActive:true, data:{test:{mods:[]}}};
const logs = [];
const localConsole = Object.fromEntries(['log','warn','error'].map(level=>[level,(...args)=>logs.push({level,message:args.map(String).join(' ')})]));
const utils = {
  readData:(key,all)=>{logs.push({config_read:key,all:!!all});return all?records.data:records[key];},
  writeData:(key,value)=>{records[key]=value;fs.writeFileSync(path.join(state, 'settings.json'),JSON.stringify(records,null,2));},
  cleanFileName:value=>value.replace(/[<>:"/\\|?*]/g,'_'),
  generateUniqueFileName:(name,extension,directory)=>{let result=name,n=1;while(fs.existsSync(path.join(directory,result+extension)))result=name+'-'+n++;return result;},
  stripBOM:value=>value.replace(/^\uFEFF/,''),
  forceDeletePath:async target=>{assert(path.resolve(target).startsWith(fixture+path.sep));await fsExtra.remove(target);},
};
const localDB = {initialized:true, removeModHeaders:()=>true};
const cache = new Map();
function load(relative) {
  const absolute=path.join(source,'obfuscated_src/main',relative);
  if(cache.has(absolute))return cache.get(absolute).exports;
  const module={exports:{}};cache.set(absolute,module);
  function localRequire(name) {
    if(['fs','path','crypto'].includes(name))return require(name);
    if(name==='fs-extra')return fsExtra;
    if(name==='extract-zip')return extractZip;
    if(name==='adm-zip')return AdmZip;
    if(name==='json5')return JSON5;
    if(name==='electron')return {dialog:{showOpenDialog:async()=>{throw new Error('Unexpected UI access');}}};
    if(name.endsWith('/utils')||name==='./utils')return utils;
    if(name.endsWith('/constants'))return {MODS_DIR:library,DATA_PATH:state};
    if(name.endsWith('/LocalDB'))return localDB;
    if(['node-unrar-js','node-7z','7zip-min','7zip-bin'].includes(name))return {};
    if(name.startsWith('.')) {
      const resolved=path.relative(path.join(source,'obfuscated_src/main'),path.resolve(path.dirname(absolute),name+'.js'));
      return load(resolved);
    }
    throw new Error('Unexpected dependency: '+name);
  }
  const context=vm.createContext({module,exports:module.exports,require:localRequire,console:localConsole,
    process:{platform:process.platform,env:{DEV:'true'},resourcesPath:''},Buffer,setTimeout,clearTimeout});
  new vm.Script(fs.readFileSync(absolute,'utf8'),{filename:absolute}).runInContext(context,{timeout:5000});
  return module.exports;
}
const handler=load('modsHandler.js');
const icons=load('modules/iconHandler.js');
const deployer=load('modules/modDeployer.js');
const remover=load('modules/modRemover.js');
const release=path.resolve(process.argv[2]);
const archiveName='9ba626afa44a3aa3.patch_0';
const listFiles=directory=>fs.readdirSync(directory,{recursive:true,withFileTypes:true}).filter(e=>e.isFile()).map(e=>path.relative(directory,path.join(e.parentPath||e.path,e.name)).replaceAll('\\','/')).sort();
const digest=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
async function verifyPresentation(mod, packageZip) {
 const manifest=JSON5.parse(packageZip.readAsText('manifest.json'));
 assert.equal(mod.label,manifest.Name);
 assert.equal(mod.description,manifest.Description);
 assert.equal(mod.options.length,1);
 if(manifest.IconPath) {
  const packIcon=await icons.getModPackIcon(mod.path);
  assert(packIcon,'Arsenal must resolve supplied artwork');
  assert.equal(digest(fs.readFileSync(packIcon)),digest(packageZip.readFile(manifest.IconPath)));
 }
}
(async()=>{
 const releases=[release,...process.argv.slice(5).map(p=>path.resolve(p))];
 assert(releases.length>=3 && releases.length<=4);
 const packages=releases.map(p=>new AdmZip(p));
 await handler.processAndValidateZipsFromRenderer(library,releases);
 assert.equal(records.modsList.length,releases.length);
 const imported=records.modsList;
 for(let i=0;i<imported.length;i++)await verifyPresentation(imported[i],packages[i]);
 const checks=[];
 const permutations=items=>items.length?items.flatMap((item,i)=>permutations(items.filter((_,j)=>j!==i)).map(rest=>[item,...rest])):[[]];
 for(const order of permutations(releases.map((_,i)=>i))) {
  for(let mask=0;mask<(1<<releases.length);mask++) {
   await remover.purgeMods();assert.equal(listFiles(game).length,0);
   let mods=order.map(i=>imported[i]);
   mods.forEach((mod,i)=>mod.enabled=!!(mask & (1<<i)));
   records.modsLibrary=mods;records.modsList=mods;records.data.test.mods=mods;
   for(let i=0;i<mods.length;i++) {
    mods=await deployer.deployMod(mods[i].uuid,mods,data,temp,state,mods);
    records.modsLibrary=mods;records.modsList=mods;records.data.test.mods=mods;
   }
   const active=order.filter((_,i)=>mask & (1<<i));
   assert.equal(listFiles(data).length,active.length*3);
   const hashes=[];
   for(let i=0;i<active.length;i++) {
    const name='9ba626afa44a3aa3.patch_'+i;
    hashes.push(digest(fs.readFileSync(path.join(data,name))));
    for(const suffix of ['.stream','.gpu_resources'])assert.equal(fs.statSync(path.join(data,name+suffix)).size,0);
   }
   assert.deepEqual(hashes.sort(),active.map(i=>digest(packages[i].readFile('data/'+archiveName))).sort());
   assert.equal(listFiles(path.join(game,'bin')).length,0);
   checks.push({order,mask,contiguous_slots:true,runtime_hashes_preserved:true});
  }
 }
 await remover.purgeMods();assert.equal(listFiles(game).length,0);
 const result={manager_version:'0.36.0',mods_imported:releases.length,
  packages:releases.map(p=>({name:path.basename(p),sha256:digest(fs.readFileSync(p))})),
  checks,live_profile_changed:false,game_launched:false};
 fs.writeFileSync(path.join(base,'pair-compatibility.json'),JSON.stringify(result,null,2));
 console.log(`PASS: Arsenal imported ${releases.length} separate mods; all ${checks.length} load-order/removal combinations preserve payloads; purge leaves an empty fixture.`);
})().catch(error=>{fs.writeFileSync(path.join(fixture,'backend-log.json'),JSON.stringify(logs,null,2));console.error(error);process.exitCode=1;});
