import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { getWatch, watch } from './subscriptions.ts';
const out = (v: unknown) => ({content:[{type:'text' as const,text:JSON.stringify(v,null,2)}],details:{}});
export function registerWatchTools(pi: ExtensionAPI, root: () => string, actor: () => string): void {
  pi.registerTool({
    name:'context_watch',label:'Watch Relevant Changes',
    description:'Watch project paths and knowledge topics. Changes are silently included at the next inference boundary.',
    parameters:Type.Object({
      paths:Type.Optional(Type.Array(Type.String())),
      topics:Type.Optional(Type.Array(Type.String())),
      replace:Type.Optional(Type.Boolean()),
    }),
    async execute(_id:string,p:any) {
      try{return out(watch(root(),actor(),{paths:p.paths,topics:p.topics},p.replace??false));}
      catch(e){return out({error:(e as Error).message});}
    },
  });
  pi.registerTool({
    name:'context_watches',label:'List Relevance Watches',
    description:'Show the project and knowledge subscriptions for this agent.',
    parameters:Type.Object({}),
    async execute(){return out(getWatch(root(),actor()));},
  });
}
