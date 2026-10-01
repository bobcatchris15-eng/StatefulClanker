import itertools, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def enumerate_ok(problem, unavailable=()):
    projects = {p['id']: p for p in problem['projects']}
    ids = sorted(projects)
    rows = []
    for n in range(1 << len(ids)):
        chosen = tuple(x for i, x in enumerate(ids) if n & (1 << i))
        s = set(chosen)
        if not set(problem['mandatory']) <= s or s & set(unavailable):
            continue
        if any(not set(req) <= s for item, req in problem['dependencies'].items() if item in s):
            continue
        if any(a in s and b in s for a, b in problem['incompatible_pairs']):
            continue
        cost = sum(projects[x]['cost'] for x in chosen)
        value = sum(projects[x]['value'] for x in chosen)
        if cost <= problem['budget']:
            rows.append({'selected':list(chosen),'cost':cost,'value':value})
    rows.sort(key=lambda r: r['selected'])
    winner = min(rows, key=lambda r: (-r['value'], r['cost'], r['selected']))
    return rows, winner

key = {}
for path in sorted((ROOT/'fixtures').glob('puzzle_*.json')):
    item = json.loads(path.read_text(encoding='utf-8'))
    p, d = item['problem'], item['delta']
    before, bw = enumerate_ok(p)
    after, aw = enumerate_ok(p, [d['project_id']])
    facts = dict(p)
    facts['unavailable'] = [d['project_id']]
    removed = [r['selected'] for r in before if d['project_id'] in r['selected']]
    key[p['problem_id']] = {'problem':p,'delta':d,'before':{'ledger':before,'winner':bw},'after':{'ledger':after,'winner':aw},'after_facts':facts,'removed':removed}
(ROOT/'private'/'answer_key.json').write_text(json.dumps(key,indent=2)+'\n',encoding='utf-8')
