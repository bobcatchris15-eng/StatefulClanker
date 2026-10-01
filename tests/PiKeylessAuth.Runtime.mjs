import { pathToFileURL } from 'node:url';
import { suppressKeylessAuth } from '../pi/extensions/keyless-auth.mjs';
const base = process.argv[2];
const { stream: streamOpenAICompletions } = await import(pathToFileURL(base + '/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js'));
const model = {id:'mock',name:'mock',api:'openai-completions',provider:'sc-keyless',baseUrl:'http://localhost:1/v1',reasoning:false,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:32000,maxTokens:100};
const context={messages:[{role:'user',content:'test',timestamp:Date.now()}]};
const authenticated={Authorization:'Bearer real-test-key'};
suppressKeylessAuth(authenticated,'sc-auth',{'sc-auth':{api:'openai-completions',apiKey:'!credential-command',authHeader:true}});
if(authenticated.Authorization !== 'Bearer real-test-key') throw new Error('Authenticated connection header changed.');
for (const corrected of [false,true]) {
 let authorization;
 const headers={};
 if(corrected) suppressKeylessAuth(headers,'sc-keyless',{'sc-keyless':{api:'openai-completions',apiKey:'statefulclanker-keyless',authHeader:false}});
 const stream=streamOpenAICompletions(model,context,{apiKey:'statefulclanker-keyless',headers,maxRetries:0,fetch:async (_url,options)=>{
  authorization=new Headers(options.headers).get('authorization');
  return new Response(JSON.stringify({error:{message:'capture complete'}}),{status:400,headers:{'content-type':'application/json'}});
 }});
 const result=await stream.result();
 if(authorization === undefined) throw new Error('Pi transport failed before capture: '+result.errorMessage);
 if(corrected ? authorization !== null : authorization !== 'Bearer statefulclanker-keyless') throw new Error('Unexpected Pi transport auth behavior: '+JSON.stringify({corrected,authorization}));
}
console.log('PASS: real Pi transport sends placeholder Bearer by default and extension removes it.');
