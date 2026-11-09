import argparse
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time
import threading
import types
ROOT = pathlib.Path(__file__).resolve().parents[2]
MASK = (1 << 64) - 1
p = argparse.ArgumentParser()
p.add_argument('--timeout', type=int, default=60)
p.add_argument('--directory', default='build/sat')
p.add_argument('--output', required=True)
p.add_argument('--depth-search', action='store_true')
a = p.parse_args()
if not 1 <= a.timeout <= 600:
    p.error('timeout must be1..600seconds')
folder = ROOT / a.directory
folder.mkdir(parents=True, exist_ok=True)
inputs = [sum(((row >> i & 1) << row for row in range(64))) for i in range(6)]
outputs = [sum(((sum((row >> i & 1 for i in range(5))) + 2 * (row >> 5 & 1) >> bit & 1) << row for row in range(64))) for bit in range(3)]

def bv(value, width):
    return f'(_ bv{value} {width})'

def choose(index, values):
    expr = values[-1]
    for i in reversed(range(len(values) - 1)):
        expr = f'(ite (= {index} {bv(i, 4)}) {values[i]} {expr})'
    return expr

def fold(op, values):
    result = values[0]
    for v in values[1:]:
        result = f'({op} {result} {v})'
    return result

def lut_expr(lut, aa, bb, cc):
    pieces = []
    for j in range(8):
        cube = fold('bvand', [aa if j & 4 else f'(bvnot {aa})', bb if j & 2 else f'(bvnot {bb})', cc if j & 1 else f'(bvnot {cc})'])
        pieces.append(f'(ite (= ((_ extract {j} {j}) {lut}) #b1) {cube} {bv(0, 64)})')
    return fold('bvor', pieces)

def query(k, fixed=False, max_depth=None):
    lines = ['(set-logic QF_BV)', '(set-option :produce-models true)', f'(set-option :timeout {a.timeout * 1000})', '(set-option :smt.random_seed 598)']
    values = [bv(x, 64) for x in inputs]
    names = []
    depths = [bv(0, 3)] * 6
    witness = [(0, 1, 2, 150), (0, 1, 2, 232), (3, 4, 6, 150), (3, 4, 6, 232), (5, 7, 9, 150), (5, 7, 9, 232)]
    for i in range(k):
        for key, width in [('a', 4), ('b', 4), ('c', 4), ('imm', 8)]:
            lines.append(f'(declare-fun {key}{i} () (_ BitVec {width}))')
            names.append(f'{key}{i}')
        lines += [f'(assert (bvult a{i} b{i}))', f'(assert (bvult b{i} c{i}))', f'(assert (bvult c{i} {bv(len(values), 4)}))']
        terms = [choose(f'{key}{i}', values) for key in ['a', 'b', 'c']]
        if max_depth is not None:
            ds = [choose(f'{key}{i}', depths) for key in ['a', 'b', 'c']]
            deep = ds[0]
            for d in ds[1:]:
                deep = f'(ite (bvugt {deep} {d}) {deep} {d})'
            lines += [f'(declare-fun depth{i} () (_ BitVec 3))', f'(assert (= depth{i} (bvadd {bv(1, 3)} {deep})))']
            depths.append(f'depth{i}')
        lines.append(f'(declare-fun t{i} () (_ BitVec 64))')
        lines.append(f"(assert (= t{i} {lut_expr(f'imm{i}', *terms)}))")
        values.append(f't{i}')
        if fixed:
            for key, value, width in zip(['a', 'b', 'c', 'imm'], witness[i], [4, 4, 4, 8]):
                lines.append(f'(assert (= {key}{i} {bv(value, width)}))')
    for i, target in enumerate(outputs):
        name = f'out{i}'
        names.append(name)
        lines += [f'(declare-fun {name} () (_ BitVec 4))', f'(assert (bvult {name} {bv(len(values), 4)}))', f'(assert (= {choose(name, values)} {bv(target, 64)}))']
        if fixed:
            lines.append(f'(assert (= {name} {bv([8, 10, 11][i], 4)}))')
        if max_depth is not None:
            lines.append(f'(assert (bvule {choose(name, depths)} {bv(max_depth, 3)}))')
    if max_depth is None:
        lines.append('(assert (or ' + ' '.join((f'(= out{i} {bv(6 + k - 1, 4)})' for i in range(3))) + '))')
    lines += ['(check-sat)', '(get-info :reason-unknown)', '(get-value (' + ' '.join(names) + '))']
    return '\n'.join(lines) + '\n'

def solve(program):
    prefix, commands = program.split('(check-sat)', 1)
    model = '(get-value' + commands.split('(get-value', 1)[1] if '(get-value' in commands else ''
    proc = subprocess.Popen(['z3', '-in'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def expire():
        try:
            proc.kill()
        except ProcessLookupError:
            pass
    watchdog = threading.Timer(a.timeout + 10, expire)
    watchdog.daemon = True
    watchdog.start()
    try:
        initial = prefix + '(check-sat)\n'
        proc.stdin.write(initial)
        proc.stdin.flush()
        status = proc.stdout.readline().strip()
        assert status in ['sat', 'unsat', 'unknown'], status
        tail = (model if status == 'sat' else '(get-info :reason-unknown)\n' if status == 'unknown' else '') + '(exit)\n'
        rest, err = proc.communicate(tail, timeout=10)
        return (status, types.SimpleNamespace(stdout=status + '\n' + rest, stderr=err, returncode=proc.returncode), initial + tail)
    finally:
        watchdog.cancel()
        watchdog.join()
        if proc.poll() is None:
            proc.kill()
            proc.communicate()

def evaluate(nodes, outs, row):
    values = [row >> i & 1 for i in range(6)]
    for aa, bb, cc, imm in nodes:
        values.append(imm >> (values[aa] << 2 | values[bb] << 1 | values[cc]) & 1)
    return sum((values[index] << bit for bit, index in enumerate(outs)))
assert all((202 >> (aa << 2 | bb << 1 | cc) & 1 == (bb if aa else cc) for aa in [0, 1] for bb in [0, 1] for cc in [0, 1]))
r = dict(status='RUNNING', started=datetime.datetime.now(datetime.timezone.utc).isoformat(), command=sys.argv, z3_version=subprocess.check_output(['z3', '-version'], text=True).strip(), source_sha256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(), model='Multioutput acyclic3-input LUTs; global BV4 unsigned parent/output selectors, arbitrary global8bit LUT functions,64Boolean truth assignments in oneBV64; sorted distinct parents; unused gates allowed.', limitations='UNSAT concerns only this circuit model. Unknown/timeout is not a lower bound and says nothing about x86 speed or complete CLI performance.', queries=[])
output = ROOT / a.output
output.parent.mkdir(parents=True, exist_ok=True)

def save():
    output.write_text(json.dumps(r, indent=2) + '\n')
save()
try:
    mux = sum(((row >> 1 & 1 if row & 1 else row >> 2 & 1) << row for row in range(64)))
    check = '(set-logic QF_BV)\n(assert (distinct ' + lut_expr('#xca', *[bv(x, 64) for x in inputs[:3]]) + ' ' + bv(mux, 64) + '))\n(check-sat)\n'
    muxstatus, muxrun, muxtext = solve(check)
    assert muxstatus == 'unsat'
    (folder / 'mux-sanity.smt2').write_text(muxtext)
    r['nonsymmetric_mux_smt_check'] = dict(status=muxstatus, returncode=muxrun.returncode)
    save()
    runs = [('known-six', 6, True, None), ('search-five', 5, False, None)] if not a.depth_search else [('known-depth3', 6, True, 3), ('known-depth2', 6, True, 2), ('search-depth2', 6, False, 2)]
    for label, k, fixed, max_depth in runs:
        text = query(k, fixed, max_depth)
        path = folder / (label + '.smt2')
        start = time.perf_counter()
        status, run, text = solve(text)
        elapsed = time.perf_counter() - start
        path.write_text(text)
        item = dict(label=label, gates=k, fixed_witness=fixed, max_output_depth=max_depth, status=status, seconds=elapsed, returncode=run.returncode, smt_sha256=hashlib.sha256(text.encode()).hexdigest(), stdout=run.stdout, stderr=run.stderr)
        if status == 'sat':
            model = {name: int(value[2:], 16 if value.startswith('#x') else 2) for name, value in re.findall('\\((a\\d+|b\\d+|c\\d+|imm\\d+|out\\d+)\\s+(#x[0-9a-fA-F]+|#b[01]+)\\)', run.stdout)}
            nodes = [tuple((model[f'{key}{i}'] for key in ['a', 'b', 'c', 'imm'])) for i in range(k)]
            outs = [model[f'out{i}'] for i in range(3)]
            for row in range(64):
                assert evaluate(nodes, outs, row) == sum((row >> i & 1 for i in range(5))) + 2 * (row >> 5 & 1), (label, row)
            item.update(nodes=nodes, outputs=outs, independent_scalar_truth_cases=64)
            toml = 'nodes = [' + ', '.join(('[' + ', '.join(map(str, node)) + ']' for node in nodes)) + ']\noutputs = [' + ', '.join(map(str, outs)) + ']\n'
            (folder / (label + '.toml')).write_text(toml)
        if fixed:
            assert status == ('unsat' if max_depth == 2 else 'sat'), 'known circuit sanity failed'
        r['queries'].append(item)
        save()
        print(label, status, elapsed, flush=True)
    r.update(status='PASS', completed=datetime.datetime.now(datetime.timezone.utc).isoformat())
    save()
except BaseException as error:
    r.update(status='FAIL', error=repr(error))
    save()
    raise
