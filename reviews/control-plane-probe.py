#!/usr/bin/env python3
"""Isolated control-plane probes. Prints only synthetic-value presence booleans."""
import concurrent.futures
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
ROOT = Path(tempfile.mkdtemp(prefix='codex-memory-probes-', dir=tempfile.gettempdir()))

def run(script, args, memory=None):
    env = os.environ.copy()
    if memory is not None:
        env['MEMORY_ROOT'] = str(memory)
    return subprocess.run([str(REPO / script), *args], capture_output=True,
                          text=True, env=env, timeout=30)

def report(test, **result):
    print(json.dumps(dict(test=test, **result)), flush=True)

report('fixture', path=str(ROOT))
values = {
    'uppercase_assignment': ('API_KEY=' + 'q' * 24, 'q' * 24),
    'lowercase_bearer': ('bearer ' + 'q' * 24, 'q' * 24),
    'jwt': ('eyJ' + 'q' * 40, 'eyJ' + 'q' * 40),
    'hex': ('9f' * 24, '9f' * 24),
}
for test, (sample, value) in values.items():
    result = run('skills/secret-scan/scripts/scan.sh',
                 ['--text', sample, '--mode', 'read'])
    status = re.search(r'Status: `([^`]+)', result.stdout)
    report('scanner_' + test, exit=result.returncode,
           status=status.group(1) if status else None,
           value_retained=value in result.stdout)

memory = ROOT / 'writer'
memory.mkdir()
result = run('skills/memory-write/scripts/write.sh',
             ['--type', 'knowledge', '--title', 'Scanner case fixture',
              '--body', values['uppercase_assignment'][0]], memory)
files = list((memory / 'knowledge').glob('*.md'))
report('writer_uppercase_assignment', exit=result.returncode,
       value_retained=bool(files and values['uppercase_assignment'][1] in files[0].read_text()),
       reports_redaction='LOW: Secret assignment value' in result.stdout)

memory = ROOT / 'supersession'
(memory / 'decisions').mkdir(parents=True)
(memory / 'index.md').write_text('# Index\n')
(memory / 'decisions' / '2026-03-topic.md').write_text(
    '# Topic cache policy\nDate: 2026-03-01\nStatus: accepted\n'
    '## Decision\n- Topic cache must use Redis.\n')
(memory / 'decisions' / '2026-04-topic.md').write_text(
    '# Topic cache policy\nDate: 2026-04-01\nStatus: accepted\n'
    'Supersedes: decisions/2026-03-topic.md\n'
    '## Decision\n- Topic cache must use SQLite.\n')
result = run('skills/decision-check/scripts/check.sh', ['topic cache'], memory)
report('supersession', exit=result.returncode,
       constraints=[line for line in result.stdout.splitlines() if line.startswith('CONSTRAINT:')],
       conflict_note='Conflict note:' in result.stdout)
result = run('skills/context-bootstrap/scripts/bootstrap.sh', ['topic cache'], memory)
report('bootstrap_supersession', exit=result.returncode,
       redis_constraint='Topic cache must use Redis.' in result.stdout,
       sqlite_constraint='Topic cache must use SQLite.' in result.stdout)

memory = ROOT / 'reader'
(memory / 'knowledge').mkdir(parents=True)
(memory / 'decisions').mkdir()
value = 'sk-proj-' + 'q' * 32
note = memory / 'knowledge' / 'fixture.md'
note.write_text('# Plain note\nThe fixture topic value is ' + value + '\n')
result = run('skills/memory-retrieve/scripts/retrieve.sh',
             ['fixture topic value', '--scopes', 'knowledge'], memory)
report('retrieval_body', exit=result.returncode, value_retained=value in result.stdout)
note.write_text('# fixture topic ' + value + '\nfixture topic body\n')
result = run('skills/memory-retrieve/scripts/retrieve.sh',
             ['fixture topic', '--scopes', 'knowledge'], memory)
report('retrieval_heading', exit=result.returncode, value_retained=value in result.stdout)
(memory / 'decisions' / 'fixture.md').write_text(
    '# fixture topic\nDate: 2026-10-12\nStatus: accepted\n'
    '## Decision\n- fixture topic value is ' + value + '\n')
result = run('skills/decision-check/scripts/check.sh', ['fixture topic'], memory)
report('decision_reader', exit=result.returncode, value_retained=value in result.stdout)

memory = ROOT / 'index_concurrency'
(memory / 'patterns').mkdir(parents=True)
(memory / 'index.md').write_text('# Index\n\n## Projects\n\n## Patterns\n\n## Knowledge\n')
for i in range(20):
    (memory / 'patterns' / f'item{i}.md').write_text('# Fixture\n')
def index_call(i):
    return run('skills/memory-index-update/scripts/update_index.sh',
               ['--change', 'add-pattern', '--path', f'patterns/item{i}.md',
                '--description', f'fixture {i}', '--title', f'item {i}'], memory).returncode
with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
    exits = list(pool.map(index_call, range(20)))
index = (memory / 'index.md').read_text()
retained = sum(f'](patterns/item{i}.md)' in index for i in range(20))
report('index_concurrency', calls=20, successful=exits.count(0), retained=retained, lost=20-retained)

memory = ROOT / 'decision_concurrency'
memory.mkdir()
def decision_call(i):
    return run('skills/decision-record/scripts/record.sh',
               ['--title', 'Concurrent policy', '--decision', f'worker {i}',
                '--context', 'fixture', '--why', 'fixture', '--tradeoffs', 'fixture',
                '--followups', '', '--date', '2026-10-12'], memory)
with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
    results = list(pool.map(decision_call, range(20)))
paths = [m.group(1) for r in results if (m := re.search(r'path: `([^`]+)', r.stdout))]
report('decision_concurrency', calls=20,
       successful=sum(r.returncode == 0 for r in results),
       files=len(list((memory / 'decisions').glob('*.md'))),
       unique_reported_paths=len(set(paths)))

memory = ROOT / 'status'
(memory / 'projects' / 'sample').mkdir(parents=True)
(memory / 'projects' / 'sample' / 'overview.md').write_text('# Sample\n## Goal\nfixture\n')
(memory / 'projects' / 'sample' / 'log.md').write_text(
    '## 2026-10-12 10:00 — old\nStatus: in progress\nNext:\n'
    '- [ ] Complete alpha\nBlockers:\n- approval pending\n\n'
    '## 2026-10-12 11:00 — new\nStatus: done\nNext:\n'
    '- [x] Complete alpha\n- [ ] Start beta\nBlockers:\n- None\n')
result = run('skills/project-status/scripts/status.sh', ['sample'], memory)
next_actions = result.stdout.split('**Next Actions:**', 1)[1].split('**Blockers', 1)[0]
blockers = result.stdout.split('**Blockers / Risks:**', 1)[1].split('**Recent', 1)[0]
report('status', exit=result.returncode,
       completed_task_in_next='Complete alpha' in next_actions,
       old_blocker_resurrected='approval pending' in blockers)
