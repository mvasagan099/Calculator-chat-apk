#!/usr/bin/env python3
"""Concurrent transactions against only the disposable local SQL-test container."""
import concurrent.futures
import subprocess
import sys
import threading

container = sys.argv[1]
if not container.startswith('calculator-sql-test-'):
    raise SystemExit('Use only the ephemeral database test harness')


def sql(statement):
    result = subprocess.run(['docker', 'exec', '-i', container, 'psql', '-XAt', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1'], input=statement, text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.splitlines()


def as_user(user, statement):
    return sql(f"begin;set local role authenticated;select set_config('request.jwt.claim.sub','{user}',true);{statement};commit;")


a = '70000000-0000-0000-0000-000000000001'
b = '70000000-0000-0000-0000-000000000002'
sql(f"insert into auth.users(id) values('{a}'),('{b}');")
cid = next(line for line in as_user(a, f"select public.create_direct('{b}')") if len(line) == 36 and line != a)
barrier = threading.Barrier(2)


def begin():
    barrier.wait(timeout=10)
    rows = as_user(a, f"select public.begin_call('{cid}',false,'71000000-0000-0000-0000-000000000001')")
    return next(line for line in rows if len(line) == 36 and line != a)


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    calls = list(executor.map(lambda _: begin(), range(2)))
if calls[0] != calls[1]:
    raise AssertionError('Concurrent retries created duplicate calls')
callid = calls[0]
print('PASS: concurrent retry transactions return one durable call ID')
barrier.reset()


def action(user, name):
    barrier.wait(timeout=10)
    return as_user(user, f"select public.transition_call('{callid}','{name}')")


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    accept = executor.submit(action, b, 'accept')
    cancel = executor.submit(action, a, 'cancel')
    accept.result()
    cancel.result()
state = sql(f"select state from public.calls where id='{callid}';")[-1]
if state not in ('ended', 'cancelled'):
    raise AssertionError(f'Race left nonterminal state: {state}')
rows = sql(f"select count(*) from public.call_history where call_id='{callid}';")[-1]
if rows != '2':
    raise AssertionError('Terminal history not atomic')
print('PASS: simultaneous accept/cancel terminates once and records both histories')
