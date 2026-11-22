import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

const canvas = document.querySelector('canvas');
const poster = document.querySelector('#fallback');
const requestedRoot = new URLSearchParams(location.search).get('assetRoot') || '';
const assetRoot = /^\/(updates|companion-assets)\/[a-z0-9][a-z0-9.-]{0,79}\/$/.test(requestedRoot) ? requestedRoot : './';
const models={clear:'companion.glb',soft:'companion-soft.glb',poised:'companion-poised.glb'};
const faceKeys=['faceWidth','faceLength','jawWidth','chinLength','eyeSize','eyeSpacing','browHeight','noseWidth','noseLength','mouthWidth'];
const neutral={version:1,preset:'clear',hair:0,outfit:0,skin:'#FFFFFF',hairColor:'#FFFFFF',eyeColor:'#FFFFFF',
  clothColor:'#6D9D89',face:Object.fromEntries(faceKeys.map(k=>[k,50]))};
const presets=Object.fromEntries(Object.keys(models).map(preset=>[preset,{...structuredClone(neutral),preset}]));
let config=structuredClone(neutral), model=null, renderer, scene, stage, floor, camera, controls, key, fill;
let mode='idle',motion='standard',view='bust',paused=false,ready=false,clock=0,previous=0,modeStart=0;
let loadEpoch=0, modelPending='';
const cache=new Map();
const loader=new GLTFLoader();
const reduced=matchMedia('(prefers-reduced-motion: reduce)');
const cameraReset=new THREE.Vector3(1.34,.48,2.85).normalize();
const temp=new THREE.Vector3(), lookTarget=new THREE.Vector3();
const clamp=(value,min,max)=>Math.max(min,Math.min(max,value));
const assetURL=path=>new URL(path,new URL(assetRoot,location.href)).href;
const validColor=/^#[a-fA-F0-9]{6}$/;
const matColor=new THREE.Color();

function notify(event) {
  window.CompanionBridge?.postMessage(JSON.stringify(event));
  if(window.parent!==window)window.parent.postMessage({source:'harbor-companion',...event},location.origin);
}
function poseCamera(reset=false) {
  if(!model||view==='manual')return;
  const close=view==='face';
  lookTarget.set(0,close?1.50:1.08,0);
  const aspect=Math.max(.5,camera.aspect);
  const distance=(close?2.56:4.10)*Math.max(1, .85/aspect);
  if(reset){controls.target.copy(lookTarget);camera.position.copy(lookTarget).addScaledVector(cameraReset,distance);return;}
  temp.copy(camera.position).sub(controls.target).normalize().multiplyScalar(distance).add(lookTarget);
  camera.position.lerp(temp,.10);
  controls.target.lerp(lookTarget,.10);
}
function setup() {
  renderer=new THREE.WebGLRenderer({canvas,alpha:true,antialias:true,powerPreference:'low-power',preserveDrawingBuffer:true});
  renderer.setPixelRatio(Math.min(devicePixelRatio,1.75));
  renderer.outputColorSpace=THREE.SRGBColorSpace;
  renderer.toneMapping=THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure=1.13;
  scene=new THREE.Scene();
  camera=new THREE.PerspectiveCamera(40,1,.05,30);
  camera.position.set(1,1.8,3.6);
  controls=new OrbitControls(camera,canvas);
  controls.enableDamping=true; controls.enablePan=false;controls.rotateSpeed=.58;
  controls.minDistance=1.75;controls.maxDistance=6.6;controls.minPolarAngle=.65;controls.maxPolarAngle=1.76;
  controls.addEventListener('start',()=>{view='manual';});
  const pmrem=new THREE.PMREMGenerator(renderer);
  const studio=new RoomEnvironment();
  scene.environment=pmrem.fromScene(studio,.07).texture;
  scene.environmentIntensity=.56;
  studio.dispose();pmrem.dispose();
  scene.add(new THREE.HemisphereLight(0xfff4e9,0x9da89c,1.18));
  key=new THREE.DirectionalLight(0xfff0de,2.1); key.position.set(-2,5,4);scene.add(key);
  fill=new THREE.DirectionalLight(0xe4f0ff,.75);fill.position.set(4,2,2);scene.add(fill);
  const rim=new THREE.DirectionalLight(0xffe3c2,1.18);rim.position.set(2,3,-4);scene.add(rim);
  stage=new THREE.Group(); scene.add(stage);
  floor=new THREE.Mesh(new THREE.CircleGeometry(1.6,64),
    new THREE.MeshBasicMaterial({map:shadowTexture(),transparent:true,opacity:.22,depthWrite:false}));
  floor.rotation.x=-Math.PI/2;floor.position.y=.009;scene.add(floor);
  const resize=()=>{
    const w=Math.max(1,canvas.clientWidth),h=Math.max(1,canvas.clientHeight);
    renderer.setSize(w,h,false);camera.aspect=w/h;camera.updateProjectionMatrix();
    if(model&&view==='bust')poseCamera(true);
  };
  new ResizeObserver(resize).observe(canvas);
  resize();
}
function shadowTexture() {
  const drawing=document.createElement('canvas');drawing.width=drawing.height=64;
  const ctx=drawing.getContext('2d');
  const gradient=ctx.createRadialGradient(32,32,0,32,32,32);
  gradient.addColorStop(0,'rgba(35,50,40,0.9)');gradient.addColorStop(.48,'rgba(35,50,40,0.48)');
  gradient.addColorStop(1,'rgba(35,50,40,0)');
  ctx.fillStyle=gradient;ctx.fillRect(0,0,64,64);
  return new THREE.CanvasTexture(drawing);
}
function addAccessory(actor) {
  if(!actor.head)return null;
  const pin=new THREE.Group();
  const sphere=new THREE.SphereGeometry(1,20,14);
  const cloth=new THREE.MeshStandardMaterial({color:neutral.clothColor,roughness:.64});
  const ivory=new THREE.MeshStandardMaterial({color:0xffebcf88,roughness:.45});
  const knot=new THREE.Mesh(sphere,ivory);knot.scale.setScalar(.055);
  const left=new THREE.Mesh(sphere,cloth);left.position.x=-.08;left.scale.set(.10,.047,.041);left.rotation.z=.28;
  const right=left.clone();right.position.x=.08;right.rotation.z=-.28;
  pin.add(knot,left,right);
  // Position the pin relative to the normalized character so all three rigs fit it.
  pin.position.set(.19,.78,.64);
  actor.root.add(pin);
  return {pin,cloth};
}
function applyShape() {
  if(!model)return;
  const shape=key=>(config.face[key]-50)/50;
  const head=model.head;
  if(head)head.scale.set(1+.16*shape('faceWidth')+.075*shape('jawWidth'),
    1+.13*shape('faceLength')+.08*shape('chinLength'),1+.12*shape('noseLength'));
  for(const ear of model.ears){
    if(!ear)continue;
    const presets=[1,.72,1.28,.88,1.12,.95];
    ear.scale.set(1+.055*shape('eyeSpacing'),presets[config.hair],1+.1*shape('browHeight'));
  }
  if(model.lids){model.lids.scale.x=1+.15*shape('eyeSpacing');model.lids.scale.y*=1+.19*shape('eyeSize');}
  if(model.jaw)model.jaw.scale.set(1+.14*shape('mouthWidth')+.08*shape('noseWidth'),1,1);
}
function applyConfig(){
  if(!model)return;
  applyShape();
  for(const mat of model.materials){
    mat.userData.coat.value.set(config.skin);
    mat.userData.markings.value.set(config.hairColor);
    mat.userData.eyes.value.set(config.eyeColor);
  }
  if(model.accessory){
    model.accessory.pin.visible=config.outfit!==0;
    model.accessory.pin.scale.setScalar(config.outfit===2?1.25:1);
    model.accessory.pin.rotation.z=config.outfit===2?-.20:.14;
    model.accessory.cloth.color.copy(matColor.set(config.clothColor));
  }
  poster.src='poster-'+config.preset+'.png';
  notify({type:'configChanged',config:getConfig()});
}
function textureTint(mat){
  mat.userData.coat={value:new THREE.Color('white')};
  mat.userData.markings={value:new THREE.Color('white')};
  mat.userData.eyes={value:new THREE.Color('white')};
  mat.onBeforeCompile=shader=>{
    shader.uniforms.coatTint=mat.userData.coat;
    shader.uniforms.markTint=mat.userData.markings;
    shader.uniforms.eyeTint=mat.userData.eyes;
    shader.fragmentShader='uniform vec3 coatTint; uniform vec3 markTint; uniform vec3 eyeTint;\n'+shader.fragmentShader;
    shader.fragmentShader=shader.fragmentShader.replace('#include <map_fragment>',`#include <map_fragment>
      vec3 pixel=diffuseColor.rgb;
      float brightness=dot(pixel,vec3(.23,.65,.12));
      float neutralMask=1.0-smoothstep(.12,.40,max(max(pixel.r,pixel.g),pixel.b)-min(min(pixel.r,pixel.g),pixel.b));
      float mask=smoothstep(.08,.35,brightness)*(1.0-neutralMask*.75);
      diffuseColor.rgb*=mix(vec3(1.0),coatTint,mask);
      diffuseColor.rgb*=mix(markTint,vec3(1.0),smoothstep(.035,.31,brightness));
      diffuseColor.rgb*=mix(eyeTint,vec3(1.0),smoothstep(.035,.23,brightness));
    `);
  };
  mat.customProgramCacheKey=()=> 'harbor-pet-color-v1';
}
async function loadPet(key) {
  let gltf;
  try{gltf=await loader.loadAsync(assetURL(models[key]));}
  catch(error){
    if(assetRoot==='./'||key==='clear')throw error;
    gltf=await loader.loadAsync(new URL(models[key],location.href).href);
  }
  const rig=gltf.scene;
  const bolts={};
  const materials=new Set();
  rig.traverse(node=>{
    if(node.isMesh){
      if(/_LOD1$/.test(node.name)){node.visible=false;return;}
      for(const mat of Array.isArray(node.material)?node.material:[node.material]){
        if(!materials.has(mat)){textureTint(mat);materials.add(mat);}
      }
      node.frustumCulled=false;
    }
    if(node.isBone)bolts[node.name]=node;
  });
  const root=new THREE.Group();root.add(rig);
  const box=new THREE.Box3().setFromObject(rig);
  const center=box.getCenter(new THREE.Vector3());
  const height=Math.max(.1,box.max.y-box.min.y);
  rig.scale.setScalar(2.13/height);
  rig.position.set(-center.x*rig.scale.x,-box.min.y*rig.scale.y,-center.z*rig.scale.z);
  rig.rotation.y=0;
  const actor={key,root,rig,head:bolts.Head,ears:[bolts.Ear_L,bolts.Ear_R],jaw:bolts.Jaw,lids:bolts.Lids,materials,
    mixer:new THREE.AnimationMixer(rig),clips:new Map(gltf.animations.map(clip=>[clip.name,clip])),playing:null};
  actor.accessory=addAccessory(actor);
  return actor;
}
async function activate() {
  const desired=config.preset;
  if(!renderer)return;
  if(model?.key===desired){if(modelPending&&modelPending!==desired){loadEpoch++;modelPending='';}applyConfig();return;}
  if(modelPending===desired)return;
  const revision=++loadEpoch;
  modelPending=desired;
  try {
    if(!cache.has(desired))cache.set(desired,loadPet(desired));
    const candidate=await cache.get(desired);
    if(revision!==loadEpoch||config.preset!==desired)return;
    modelPending='';
    if(model)stage.remove(model.root);
    model=candidate;stage.add(model.root);
    view='bust';poseCamera(true);controls.update();applyConfig();
    playState();poster.hidden=true;ready=true;notify({type:'ready',version:1});
  } catch (error) {
    cache.delete(desired);
    if(revision!==loadEpoch)return;
    modelPending='';poster.hidden=false;
    if(!model)ready=false;
    notify({type:'error',message:'无法加载伙伴形象',detail:String(error)});
  }
}
function playState(){
  if(!model)return;
  const clips={greeting:'jump',reply:'call',thinking:'idle_alt',listening:'sit',farewell:'sleep',help:'idle',idle:'idle'};
  const name=motion==='still'||reduced.matches?'idle':clips[mode];
  const clip=model.clips.get(name)||model.clips.get('idle');
  if(!clip)return;
  const next=model.mixer.clipAction(clip);
  if(next===model.playing)return;
  const prior=model.playing;
  const loop=['idle','idle_alt','sit','sleep'].includes(name);
  next.reset().setLoop(loop?THREE.LoopRepeat:THREE.LoopOnce,loop?Infinity:1);
  next.clampWhenFinished=!loop;
  next.fadeIn(.18).play();
  if(prior)prior.fadeOut(.18);
  model.playing=next;
}
function animate(timestamp) {
  requestAnimationFrame(animate);
  if(!renderer||paused||document.hidden){previous=0;return;}
  const dt=previous?Math.min(.05,(timestamp-previous)/1000):0;
  previous=timestamp;clock+=dt;
  if(model){
    if(motion!=='still'&&!reduced.matches&&mode!=='help'){
      model.mixer.update(dt*(motion==='subtle'?.75:1));
      applyShape();
      if(['greeting','reply'].includes(mode)&&clock-modeStart>1.6)setState('idle');
    }
    poseCamera();
  }
  controls.update();
  renderer.render(scene,camera);
}
function setConfig(value={}) {
  const base=presets[value.preset]&&value.preset!==config.preset?presets[value.preset]:config;
  config={...base,...value,version:1,face:{...base.face,...value.face}};
  config.preset=models[config.preset]?config.preset:'clear';
  config.hair=clamp(Math.round(Number(config.hair)||0),0,5);
  config.outfit=clamp(Math.round(Number(config.outfit)||0),0,2);
  for(const name of faceKeys)config.face[name]=clamp(Number(config.face[name])||0,0,100);
  for(const name of ['skin','hairColor','eyeColor','clothColor'])if(!validColor.test(config[name]))config[name]=neutral[name];
  activate();
}
function getConfig(){return structuredClone(config);}
function setState(next){if(next===mode||!['idle','greeting','listening','thinking','reply','farewell','help'].includes(next))return;mode=next;modeStart=clock;playState();}
function setMotion(level){if(!['standard','subtle','still'].includes(level)||motion===level)return;motion=level;playState();}
function setTheme(theme){document.documentElement.dataset.theme=theme==='dark'?'dark':'light';if(fill)fill.intensity=theme==='dark'?1.05:.75;}
function setPaused(value){paused=Boolean(value);}
function setView(next){view=next==='face'?'face':'bust';}
function resetCamera(){view='bust';poseCamera(true);}
function screenshot(){return canvas.toDataURL('image/png');}
window.Companion={setConfig,getConfig,setState,setMotion,setTheme,setPaused,setView,resetCamera,screenshot,presets,get ready(){return ready;}};
window.addEventListener('message',event=>{
  if(event.source!==window.parent||event.origin!==location.origin||!event.data)return;
  const m=event.data;
  ({config:()=>setConfig(m.config),state:()=>setState(m.state),motion:()=>setMotion(m.motion),theme:()=>setTheme(m.theme),
    paused:()=>setPaused(m.paused),view:()=>setView(m.view),reset:resetCamera})[m.type]?.();
});
canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();notify({type:'error',message:'当前设备暂时无法显示 3D 形象'});});
if(new URLSearchParams(location.search).has('qa')){
  window.__companionQA={get model(){return model;},get clip(){return model?.playing?.getClip().name;},setAngle(theta){
    view='manual';
    const distance=camera.position.distanceTo(controls.target);
    camera.position.set(Math.sin(theta)*distance,controls.target.y+.22,Math.cos(theta)*distance);controls.update();
  }};
}
try{setup();activate();requestAnimationFrame(animate);}
catch(error){poster.hidden=false;notify({type:'error',message:'当前设备无法显示 3D 形象',detail:String(error)});}
