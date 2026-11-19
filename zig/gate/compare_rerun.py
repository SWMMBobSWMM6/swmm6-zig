# compare_rerun.py - the independent rerun against the first gate runs: for every model of the zig6_v* runs, its
# status, .out SHA-256 and .rpt SHA-256 (gate.py's hashes) against the model's last result in the zig6_c* and zig6_x*
# runs. Prints a line per difference and the totals. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports.
import glob, json, os
H = os.path.dirname(os.path.abspath(__file__)); G = os.path.join(H, '..', '..', 'gate', 'results')


def last(prefixes):
    out = {}
    for p in prefixes:
        for f in sorted(glob.glob(os.path.join(G, p + '*.json'))):
            for r in json.load(open(f)):
                out[r['id']] = r
    return out


first = last(['zig6_c', 'zig6_x'])
v = last(['zig6_v'])
same = diff = 0
for i, r in sorted(v.items()):
    f = first.get(i)
    keys = ('status', 'out_sha256', 'rpt_sha256')
    if f and all(f.get(k) == r.get(k) for k in keys):
        same += 1
    else:
        diff += 1
        print('DIFFERENT', i, r['path'], {k: (f.get(k) if f else None, r.get(k)) for k in keys})
st = {}
for r in v.values():
    st[r['status']] = st.get(r['status'], 0) + 1
print('rerun: %d models, %s; status and .out and .rpt hashes equal to the first run for %d, different for %d'
      % (len(v), ', '.join('%s %d' % kv for kv in sorted(st.items())), same, diff))
