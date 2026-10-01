import itertools
import json
import random
import hashlib
import argparse
import sys
import zlib
import base64
from pathlib import Path

MOD=11
SEEDS=(3101,3102,3103)
class StructuralError(ValueError): pass

def _det(a,b,c,d): return (a*d-b*c)%MOD
def _aff(coeff,xy): return (coeff[0]*xy[0]+coeff[1]*xy[1]+coeff[2])%MOD

def make_case(seed):
    rng=random.Random(seed)
    while True:
        pts=rng.sample(list(itertools.product(range(MOD),repeat=2)),3)
        if _det(pts[1][0]-pts[0][0],pts[1][1]-pts[0][1],pts[2][0]-pts[0][0],pts[2][1]-pts[0][1]): break
    while True:
        u=(rng.randrange(MOD),rng.randrange(MOD),rng.randrange(MOD)); v=(rng.randrange(MOD),rng.randrange(MOD),rng.randrange(MOD))
        if _det(u[0],u[1],v[0],v[1]): break
    target_xy=(rng.randrange(MOD),rng.randrange(MOD))
    observations=[{"xy":list(p),"uv":[_aff(u,p),_aff(v,p)]} for p in pts]
    return {"seed":seed,"modulus":MOD,"observations":observations,"relation":{"u":list(u),"v":list(v)},"target":{"xy":list(target_xy),"uv":[_aff(u,target_xy),_aff(v,target_xy)]}}

def score_relation(relation,target,expected):
    solutions=[(x,y) for x,y in itertools.product(range(MOD),repeat=2) if _aff(relation["u"],(x,y))==target[0] and _aff(relation["v"],(x,y))==target[1]]
    return {"correct":solutions==[tuple(expected)],"solutions":len(solutions)}
def relation_solutions(relation,target):
    return [(x,y) for x,y in itertools.product(range(MOD),repeat=2) if _aff(relation["u"],(x,y))==target[0] and _aff(relation["v"],(x,y))==target[1]]
def response_agreement(response,solutions):
    if response.get("status")=="underdetermined": return {"agreement":len(solutions)!=1,"classification":"underdetermined"}
    answer=(response["x"],response["y"])
    return {"agreement":answer in solutions,"classification":"solved","answer_in_solution_set":answer in solutions}

def validate_consumer_response(value):
    if not isinstance(value,dict): return False
    if value=={"status":"underdetermined"}: return True
    return set(value)=={"status","x","y"} and value.get("status")=="solved" and type(value.get("x")) is int and type(value.get("y")) is int

def _read(path): return json.loads(Path(path).read_text(encoding="utf-8"))
def _write(path,obj):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True); tmp=p.with_suffix(p.suffix+".tmp"); tmp.write_text(json.dumps(obj,sort_keys=True,indent=2)+"\n",encoding="utf-8"); tmp.replace(p)
def load_campaign(path): return _read(path)
def prepare(path):
    cases={str(s):{"seed":s,"version":0,"relation":None,"producer_raw":None,"cached_answer":None,"consumer_raw":{},"revision_raw":None,"revision":None} for s in SEEDS}
    campaign={"schema":"lab3-campaign-v1","modulus":MOD,"cases":cases,"schedule":_schedule()}
    campaign["schedule_hash"]=hashlib.sha256(json.dumps(campaign["schedule"],separators=(",",":")).encode()).hexdigest(); _write(path,campaign); return campaign
def _schedule():
    blocks=[]
    for s in SEEDS:
        consumers=[{"case":s,"stage":"consumer","arm":a} for a in ("intact","omitted","altered","raw")]
        random.Random(s).shuffle(consumers)
        blocks.append([{"case":s,"stage":"producer"}]+consumers+[{"case":s,"stage":"revision_producer"},{"case":s,"stage":"consumer","arm":"revised"}])
    random.Random(3101).shuffle(blocks)
    return [row for block in blocks for row in block]
def _case(campaign,case):
    key=str(case)
    if key not in campaign["cases"]: raise StructuralError("unknown case")
    return campaign["cases"][key]
def _triple(x): return isinstance(x,list) and len(x)==3 and all(type(v) is int and 0<=v<MOD for v in x)
def _patch(patch,revision=False):
    expected={"base_version","u","v"}|({"invalidate"} if revision else set())
    if not isinstance(patch,dict) or set(patch)!=expected: raise StructuralError("patch schema mismatch")
    version=1 if revision else 0
    if type(patch["base_version"]) is not int or patch["base_version"]!=version: raise StructuralError("wrong base version")
    if not _triple(patch["u"]) or not _triple(patch["v"]): raise StructuralError("coefficients must be three integer residues")
    if revision and patch["invalidate"] != ["answer"]: raise StructuralError("revision must invalidate answer")
def submit_producer(path,case,response,raw=None):
    c=load_campaign(path); st=_case(c,case)
    if st["version"]!=0 or st["relation"] is not None: raise StructuralError("producer state already submitted")
    _patch(response); st.update(version=1,relation={"u":response["u"],"v":response["v"]},producer_raw=response,producer_relation={"u":response["u"],"v":response["v"]},producer_raw_bytes=raw.decode("utf-8") if raw is not None else json.dumps(response)); _write(path,c); return {"accepted":True,"version":1}
def cache_answer(path,case,response):
    c=load_campaign(path); st=_case(c,case)
    st["cached_answer"]=response if validate_consumer_response(response) else None
    _write(path,c)
def submit_revision(path,case,response):
    c=load_campaign(path); st=_case(c,case)
    if st["version"]!=1 or st["relation"] is None: raise StructuralError("revision requires accepted producer state")
    _patch(response,True); st.update(version=2,relation={"u":response["u"],"v":response["v"]},revision=response,revision_raw=response,revision_relation={"u":response["u"],"v":response["v"]},cached_answer=None); _write(path,c); return {"accepted":True,"version":2,"invalidated":["answer"]}
def submit_consumer(path,case,arm,response):
    if arm not in ("intact","omitted","altered","raw","revised"): raise StructuralError("unknown arm")
    if not validate_consumer_response(response): raise StructuralError("consumer response shape invalid")
    c=load_campaign(path); st=_case(c,case)
    if arm=="revised" and st["version"]<2: raise StructuralError("revised relation unavailable")
    if arm in st["consumer_raw"]: raise StructuralError("consumer response already saved")
    st["consumer_raw"][arm]=response
    if arm=="intact": st["cached_answer"]=response
    _write(path,c); return {"accepted":True}
def _original(case): return make_case(int(case))
def _relation_text(rel): return "u=("+", ".join(map(str,rel["u"]))+"); v=("+", ".join(map(str,rel["v"]))+") mod 11."
def _producer_prompt(case):
    data=_original(case)
    return "Infer the coefficients in u=(a*x+b*y+c) mod 11 and v=(d*x+e*y+f) mod 11 from these three labeled observations. Return JSON only: {\"base_version\":0,\"u\":[a,b,c],\"v\":[d,e,f]}.\nObservations: "+json.dumps(data["observations"])
def _consumer_prompt(relation,target,neutral="Solve for integer residues x,y in mod 11 from the supplied relation and target. Return exactly {\"status\":\"solved\",\"x\":int,\"y\":int} or {\"status\":\"underdetermined\"}. Return JSON only."):
    relation_text="No relation was supplied." if relation is None else "Use u=(a*x+b*y+c) mod 11 and v=(d*x+e*y+f) mod 11. Relation: "+_relation_text(relation)
    return neutral+"\n"+relation_text+"\nTarget (u,v): "+json.dumps(target)
def _raw_prompt(case):
    data=_original(case)
    return "Solve for integer residues x,y in mod 11 for the target using the observations. Return exactly {\"status\":\"solved\",\"x\":int,\"y\":int} or {\"status\":\"underdetermined\"}. Return JSON only.\nObservations: "+json.dumps(data["observations"])+"\nTarget (u,v): "+json.dumps(data["target"]["uv"])
def _save_prompt(campaign,case,name,prompt):
    p=Path(campaign).parent/"prompts"/str(case)/(name+".txt"); p.parent.mkdir(parents=True,exist_ok=True)
    content=(prompt+"\n").encode("utf-8")
    if p.exists() and p.read_bytes()!=content: raise StructuralError("existing prompt differs; refusing overwrite")
    if not p.exists(): p.write_bytes(content)
    _record_hash(campaign,"prompts",str(case)+"/"+name,p.read_bytes())
    return p
def _record_hash(campaign,category,key,content):
    path=Path(campaign); hashes=path.parent/"hashes.json"
    records=_read(hashes) if hashes.exists() else {}
    digest=hashlib.sha256(content).hexdigest(); token=category+":"+key
    if token in records and records[token]!=digest: raise StructuralError("hash record conflict")
    records[token]=digest; _write(hashes,records)
def producer_prompt(campaign,case): return _save_prompt(campaign,case,"producer",_producer_prompt(case))
def consumer_prompts(campaign,case):
    c=load_campaign(campaign); st=_case(c,case)
    if st["version"]<1: raise StructuralError("producer state unavailable")
    data=_original(case)
    if st["version"]>=2:
        return {"revised":str(_save_prompt(campaign,case,"consumer-revised",_consumer_prompt(st["relation"],data["target"]["uv"]))) }
    out={}
    for arm in ("intact","omitted","altered","raw"):
        if arm=="intact": prompt=_consumer_prompt(st["relation"],data["target"]["uv"])
        elif arm=="omitted": prompt=_consumer_prompt(None,data["target"]["uv"])
        elif arm=="altered":
            rel={"u":st["relation"]["u"][:],"v":st["relation"]["v"][:]}; rel["u"][2]=(rel["u"][2]+1)%MOD; prompt=_consumer_prompt(rel,data["target"]["uv"])
        else: prompt=_raw_prompt(case)
        out[arm]=str(_save_prompt(campaign,case,"consumer-"+arm,prompt))
    return out
def revision_prompt(campaign,case):
    c=load_campaign(campaign); st=_case(c,case)
    if st["version"]!=1: raise StructuralError("revision requires producer state")
    data=_original(case); old=st["relation"]; u=old["u"][:]; u[2]=(u[2]+2)%MOD
    pts=tuple(tuple(o["xy"]) for o in data["observations"])
    obs=[{"xy":list(p),"uv":[_aff(u,p),_aff(old["v"],p)]} for p in pts]
    prompt="Update the stored relation using u=(a*x+b*y+c) mod 11 and v=(d*x+e*y+f) mod 11 from these authoritative replacement u observations. The prior cached answer is dependent on the old relation and must be invalidated. Preserve untouched v information. Return JSON only: {\"base_version\":1,\"u\":[a,b,c],\"v\":[d,e,f],\"invalidate\":[\"answer\"]}.\nPrior relation: "+_relation_text(old)+"\nCached downstream answer: "+json.dumps(st["cached_answer"])+"\nReplacement observations: "+json.dumps(obs)
    return _save_prompt(campaign,case,"revision-producer",prompt)
def summary(campaign):
    c=load_campaign(campaign); out={"schema":c["schema"],"schedule_hash":c["schedule_hash"],"planned_calls":len(c["schedule"]),"cases":{}}
    for k,st in c["cases"].items():
        out["cases"][k]={"producer_accepted":st["version"]>=1,"revision_accepted":st["version"]>=2,"consumer_arms":sorted(st["consumer_raw"]),"attrition":None if st["version"]>=1 else "producer malformed or absent"}
    return out
def evaluate(campaign):
    """Offline-only scoring; never called by submit or prompt construction."""
    c=load_campaign(campaign); results={}
    for key,st in c["cases"].items():
        world=_original(key); target=world["target"]["uv"]; expected=world["target"]["xy"]
        row={"producer_relation":None,"arms":{},"revision":None}
        base=st.get("producer_relation")
        if base:
            row["producer_relation"]={"u_exact":base["u"]==world["relation"]["u"],"v_exact":base["v"]==world["relation"]["v"],"joint_exact":base==world["relation"]}
            for arm,response in st["consumer_raw"].items():
                if arm=="revised": continue
                if arm=="omitted":
                    answer=[response["x"],response["y"]] if response.get("status")=="solved" else None
                    row["arms"][arm]={"classification":"underdetermined" if answer is None else "answered_without_relation","true_world_correct":None if answer is None else answer==list(expected),"true_world_answer":expected}
                    continue
                if arm=="raw": rel=world["relation"]
                elif arm=="altered":
                    rel={"u":base["u"][:],"v":base["v"][:]}; rel["u"][2]=(rel["u"][2]+1)%MOD
                else: rel=base
                solutions=relation_solutions(rel,target)
                answer=[response["x"],response["y"]] if response.get("status")=="solved" else None
                true_score=answer==expected if answer is not None else False
                row["arms"][arm]={"response_correct_under_conditioned_relation":response_agreement(response,solutions)["agreement"],"conditional_solution_count":len(solutions),"conditional_solution_set":[list(p) for p in solutions],"true_world_correct":true_score}
        revision=st.get("revision_relation")
        if revision:
            old=world["relation"]; revised_u=old["u"][:]; revised_u[2]=(revised_u[2]+2)%MOD
            row["revision"]={"u_exact":revision["u"]==revised_u,"v_preserved":revision["v"]==old["v"],"cache_invalidated":st.get("cached_answer") is None}
            response=st["consumer_raw"].get("revised")
            if response:
                answer=[response["x"],response["y"]] if response.get("status")=="solved" else None
                target2=target
                solutions=relation_solutions(revision,target2)
                row["revision"]["consumer_agreement_with_submitted_revision"]=response_agreement(response,solutions)["agreement"]
                row["revision"]["conditional_solution_set"]=[list(p) for p in solutions]
                row["revision"]["consumer_true_world_correct"]=answer==expected if answer is not None else False
                intended_solutions=relation_solutions({"u":revised_u,"v":old["v"]},target)
                row["revision"]["consumer_intended_revised_world_correct"]=(tuple(answer) in intended_solutions) if answer is not None else False
                row["revision"]["consumer_conditional_solution_count"]=len(solutions)
        results[key]=row
    return {"offline_only":True,"cases":results}

def _cli():
    p=argparse.ArgumentParser(); sub=p.add_subparsers(dest="cmd",required=True)
    for name in ("prepare","producer-prompt","submit-producer","consumer-prompts","submit-consumer","revision-prompt","submit-revision","summary","evaluate"):
        q=sub.add_parser(name); q.add_argument("--campaign",required=name!="prepare");
        if name=="prepare": q.add_argument("--out-dir",required=True)
        elif name not in ("summary","evaluate"): q.add_argument("--case",required=True)
        if name=="submit-consumer": q.add_argument("--arm",required=True)
        if name in ("submit-producer","submit-consumer","submit-revision"): q.add_argument("--response",required=True,help="JSON string or path to JSON file")
    a=p.parse_args()
    if a.cmd=="prepare": print(json.dumps(prepare(Path(a.out_dir)/"campaign.json"),indent=2)); return
    path=Path(a.campaign)
    def response():
        raw=a.response
        candidate=Path(raw)
        if candidate.exists(): source=candidate.read_bytes()
        else: source=raw.encode("utf-8")
        receipts=path.parent/"responses"/str(a.case); receipts.mkdir(parents=True,exist_ok=True)
        arm=getattr(a,"arm",None)
        name={"submit-producer":"producer","submit-revision":"revision-producer","submit-consumer":"consumer-"+str(arm)}[a.cmd]
        receipt=receipts/(name+".raw")
        if receipt.exists(): raise StructuralError("raw response already recorded; refusing overwrite")
        receipt.write_bytes(source)
        _record_hash(path,"responses",str(a.case)+"/"+name,source)
        return json.loads(source.decode("utf-8")),source
    if a.cmd=="producer-prompt": print(producer_prompt(path,a.case))
    elif a.cmd=="consumer-prompts": print(json.dumps(consumer_prompts(path,a.case),indent=2))
    elif a.cmd=="revision-prompt": print(revision_prompt(path,a.case))
    elif a.cmd=="submit-producer":
        obj,raw=response(); print(json.dumps(submit_producer(path,a.case,obj,raw)))
    elif a.cmd=="submit-revision": print(json.dumps(submit_revision(path,a.case,response()[0])))
    elif a.cmd=="submit-consumer": print(json.dumps(submit_consumer(path,a.case,a.arm,response()[0])))
    elif a.cmd=="summary": print(json.dumps(summary(path),indent=2))
    else: print(json.dumps(evaluate(path),indent=2))
if __name__=="__main__": _cli()
