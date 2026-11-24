#!/usr/bin/env python3
"""POSIX counterpart of compare-parity.ps1, with the same inputs, output and exit codes.

Usage: compare-parity.py --baseline DIR --candidate DIR [--accepted FILE] [--json-report FILE]
See compare-parity.ps1 for the comparison rules and the accepted-differences format.
"""
import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

STATUS_ORDER = ['failed', 'passed', 'skipped']
CATEGORIES = ['missing', 'added', 'newly-failing', 'newly-passing', 'status-changed', 'step-changed']


class InputError(Exception):
    pass


def run_root(path):
    if not os.path.isdir(path):
        raise InputError('Not a directory: %s' % path)
    return os.path.realpath(path)


def junit_dir(root):
    j = os.path.join(root, 'junit')
    return j if os.path.isdir(j) else root


def read_suites(directory):
    suites = {}
    for name in sorted(os.listdir(directory)):
        full = os.path.join(directory, name)
        if not name.lower().endswith('.xml') or not os.path.isfile(full):
            continue
        suite = name[:-4]
        try:
            tree = ET.parse(full)
        except ET.ParseError as e:
            raise InputError('Cannot parse %s: %s' % (full, e))
        groups = {}
        for tc in tree.getroot().iter('testcase'):
            cls = tc.get('classname') or tc.get('class') or ''
            tid = '%s::%s::%s' % (suite, cls, tc.get('name') or '')
            if tc.find('failure') is not None or tc.find('error') is not None:
                status = 'failed'
            elif tc.find('skipped') is not None:
                status = 'skipped'
            else:
                status = 'passed'
            try:
                t = float(tc.get('time') or 0)
            except ValueError:
                t = 0.0
            groups.setdefault(tid, []).append((status, t))
        # Jasmine runs specs in random order, so same-named specs are numbered by status, not by position.
        tests = {}
        for tid, members in groups.items():
            members.sort(key=lambda m: (STATUS_ORDER.index(m[0]), m[1]))
            for k, m in enumerate(members):
                tests[tid if k == 0 else '%s #%d' % (tid, k + 1)] = m
        suites[suite] = tests
    return suites


def read_steps(root):
    p = os.path.join(root, 'steps.tsv')
    if not os.path.isfile(p):
        return None
    steps = {}
    with open(p, encoding='utf-8-sig') as fh:
        lines = fh.read().splitlines()
    for i, line in enumerate(lines[1:], start=2):
        if not line.strip():
            continue
        cols = line.split('\t')
        if len(cols) < 2:
            raise InputError('Bad steps.tsv line %d in %s' % (i, p))
        steps[cols[0]] = cols[1]
    return steps


def pattern_regex(pattern):
    return re.compile('^' + re.escape(pattern).replace('\\*', '.*').replace('\\?', '.') + '$', re.DOTALL)


def read_accepted(path):
    if not path:
        return []
    if not os.path.isfile(path):
        raise InputError('Accepted-differences file not found: %s' % path)
    try:
        with open(path, encoding='utf-8-sig') as fh:
            data = json.load(fh)
    except ValueError as e:
        raise InputError('Cannot parse accepted-differences file %s: %s' % (path, e))
    if not isinstance(data, dict) or 'accepted' not in data:
        raise InputError("Accepted-differences file has no 'accepted' array: %s" % path)
    entries = data['accepted']
    if isinstance(entries, dict):
        entries = [entries]
    out = []
    for i, e in enumerate(entries or [], start=1):
        for field in ('category', 'test', 'reason'):
            if not isinstance(e, dict) or not e.get(field):
                raise InputError("Accepted entry %d is missing '%s'" % (i, field))
        if e['category'] != '*' and e['category'] not in CATEGORIES:
            raise InputError("Accepted entry %d has unknown category '%s'" % (i, e['category']))
        out.append({'category': str(e['category']), 'test': str(e['test']), 'reason': str(e['reason']),
                    'regex': pattern_regex(str(e['test'])), 'used': 0})
    return out


def counts(tests):
    if tests is None:
        return None
    c = {'tests': len(tests), 'passed': 0, 'failed': 0, 'skipped': 0}
    for status, _ in tests.values():
        c[status] += 1
    return c


def fmt_counts(c):
    if c is None:
        return 'absent'
    return '%d tests (%d passed, %d failed, %d skipped)' % (c['tests'], c['passed'], c['failed'], c['skipped'])


def ordinal(items):
    # Ordinal UTF-16 order, matching [StringComparer]::Ordinal in PowerShell.
    return sorted(set(items), key=lambda s: s.encode('utf-16-be'))


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--baseline', required=True)
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--accepted')
    ap.add_argument('--json-report')
    args = ap.parse_args(argv)
    try:
        base_root = run_root(args.baseline)
        cand_root = run_root(args.candidate)
        base = read_suites(junit_dir(base_root))
        cand = read_suites(junit_dir(cand_root))
        accepted = read_accepted(args.accepted)
        base_steps = read_steps(base_root)
        cand_steps = read_steps(cand_root)
    except (InputError, OSError) as e:
        sys.stderr.write('compare-parity: %s\n' % e)
        return 2

    diffs = []

    def add(cat, tid, frm, to):
        diffs.append({'category': cat, 'test': tid, 'baseline': frm, 'candidate': to, 'accepted': False, 'reason': ''})

    summary = []
    for s in ordinal(list(base) + list(cand)):
        b, c = base.get(s), cand.get(s)
        summary.append((s, counts(b), counts(c)))
        for tid in ordinal(list(b or {}) + list(c or {})):
            bs = b[tid][0] if b and tid in b else None
            cs = c[tid][0] if c and tid in c else None
            if cs is None:
                add('missing', tid, bs, 'absent')
            elif bs is None:
                add('added', tid, 'absent', cs)
            elif bs == cs:
                continue
            elif cs == 'failed':
                add('newly-failing', tid, bs, cs)
            elif bs == 'failed' and cs == 'passed':
                add('newly-passing', tid, bs, cs)
            else:
                add('status-changed', tid, bs, cs)

    if base_steps is not None and cand_steps is not None:
        for st in ordinal(list(base_steps) + list(cand_steps)):
            bv = 'exit ' + base_steps[st] if st in base_steps else 'absent'
            cv = 'exit ' + cand_steps[st] if st in cand_steps else 'absent'
            if bv != cv:
                add('step-changed', 'step::' + st, bv, cv)

    for d in diffs:
        for a in accepted:
            if a['category'] in ('*', d['category']) and a['regex'].match(d['test']):
                d['accepted'], d['reason'] = True, a['reason']
                a['used'] += 1
                break

    final = [d for cat in CATEGORIES for d in diffs if d['category'] == cat]
    unaccepted = sum(1 for d in final if not d['accepted'])
    result = 'FAIL' if unaccepted else 'PASS'
    lines = ['Parity report', 'Baseline:  ' + base_root, 'Candidate: ' + cand_root]
    for s, bc, cc in summary:
        lines.append('Suite %s: baseline %s; candidate %s' % (s, fmt_counts(bc), fmt_counts(cc)))
    lines.append('Differences: %d (%d unaccepted, %d accepted)' % (len(final), unaccepted, len(final) - unaccepted))
    for d in final:
        line = '%s %s %s (%s -> %s)' % ('[accepted]' if d['accepted'] else '[UNACCEPTED]', d['category'], d['test'],
                                        d['baseline'], d['candidate'])
        if d['accepted']:
            line += ' reason: ' + d['reason']
        lines.append(line)
    for a in accepted:
        if not a['used']:
            lines.append('Unused accepted entry: %s %s' % (a['category'], a['test']))
    lines.append('Result: ' + result)
    text = '\n'.join(lines) + '\n'
    if sys.stdout.isatty():
        sys.stdout.write(text)
    else:
        # Redirected output is always UTF-8 with LF, matching compare-parity.ps1.
        sys.stdout.flush()
        sys.stdout.buffer.write(text.encode('utf-8'))
        sys.stdout.buffer.flush()

    if args.json_report:
        report = {
            'baseline': base_root, 'candidate': cand_root, 'result': result,
            'unaccepted': unaccepted, 'accepted': len(final) - unaccepted,
            'suites': [{'suite': s, 'baseline': bc, 'candidate': cc} for s, bc, cc in summary],
            'differences': final,
            'unusedAccepted': [{'category': a['category'], 'test': a['test']} for a in accepted if not a['used']],
        }
        with open(args.json_report, 'w', encoding='utf-8') as fh:
            json.dump(report, fh, indent=2)
    return 1 if unaccepted else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
