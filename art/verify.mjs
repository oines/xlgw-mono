import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';

const assets = new URL('../apps/mobile/assets/companion/', import.meta.url).pathname;
const origin = process.env.COMPANION_ORIGIN || 'http://localhost:8347';
const output = process.argv[2];
const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH,
  args: ['--enable-webgl','--use-angle=swiftshader','--enable-unsafe-swiftshader'],
});
try {
  const page = await browser.newPage({ viewport:{width:440,height:390},deviceScaleFactor:1 });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => {if(message.type()==='error' && message.text().includes('THREE'))errors.push(message.text());});
  await page.goto(origin+'/?qa=1');
  await page.waitForFunction(() => window.Companion?.ready);
  await mkdir(join(assets,'thumbnails'),{recursive:true});
  if(output)await mkdir(output,{recursive:true});
  for (const preset of ['clear','soft','poised']) {
    await page.evaluate(preset=>Companion.setConfig(Companion.presets[preset]),preset);
    await page.waitForFunction(preset=>window.__companionQA.model?.key===preset,preset);
    await page.evaluate(()=>Companion.resetCamera());
    await page.waitForTimeout(220);
    await page.screenshot({path:join(assets,'poster-'+preset+'.png')});
    if(output) {
      const name={clear:'kitten',soft:'fox',poised:'owl'}[preset];
      await page.screenshot({path:join(output,name+'-three-quarter.png')});
      await page.evaluate(()=>__companionQA.setAngle(0));
      await page.screenshot({path:join(output,name+'-front.png')});
    }
  }
  await page.evaluate(()=>Companion.setConfig(Companion.presets.clear));
  await page.waitForFunction(()=>__companionQA.model?.key==='clear');
  for(let hair=0;hair<6;hair++){
    await page.evaluate(hair=>{Companion.setConfig({hair});Companion.setView('face');},hair);
    await page.waitForTimeout(220);
    await page.screenshot({path:join(assets,'thumbnails','hair-'+hair+'.png')});
  }
  for(let outfit=0;outfit<3;outfit++){
    await page.evaluate(outfit=>{Companion.setConfig({hair:0,outfit});Companion.resetCamera();},outfit);
    await page.waitForTimeout(220);
    await page.screenshot({path:join(assets,'thumbnails','outfit-'+outfit+'.png')});
  }
  await page.evaluate(()=>{Companion.setConfig({...Companion.presets.clear,outfit:2,skin:'#C7F2CF'});Companion.setTheme('dark');Companion.setState('listening');});
  await page.waitForFunction(()=>__companionQA.clip==='sit');
  await page.waitForTimeout(300);
  if(output)await page.screenshot({path:join(output,'kitten-custom-dark.png')});
  await page.evaluate(()=>Companion.setState('greeting'));
  await page.waitForFunction(()=>__companionQA.clip==='jump');
  console.log('3 models loaded, 9 thumbnails rendered, listening and greeting actions verified');
  if(errors.length)throw new Error(errors.join('\n'));
}finally{await browser.close();}
