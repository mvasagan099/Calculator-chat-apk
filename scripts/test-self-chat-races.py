#!/usr/bin/env python3
"""Race the real RPC only inside the disposable SQL-test harness."""
from concurrent.futures import ThreadPoolExecutor
import subprocess
import sys
import threading

container = sys.argv[1]
if not container.startswith('calculator-sql-test-'):
    raise SystemExit('Use only the ephemeral database test harness')
owner = '14000000-0000-0000-0000-000000000001'


def sql(statement):
    result = subprocess.run(['docker', 'exec', '-i', container, 'psql', '-XAt', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1'],
                            input=statement, text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.splitlines()


sql(f"insert into auth.users(id) values('{owner}');")
barrier = threading.Barrier(2)


def create(_):
    barrier.wait(timeout=10)
    rows = sql(f"begin;set local role authenticated;select set_config('request.jwt.claim.sub','{owner}',true);select public.create_direct('{owner}');commit;")
    return next(row for row in rows if len(row) == 36 and row != owner)


with ThreadPoolExecutor(max_workers=2) as executor:
    conversations = list(executor.map(create, range(2)))
assert conversations[0] == conversations[1], 'Concurrent self chats duplicated'
cid = conversations[0]
assert sql(f"select count(*) from public.conversations where direct_key='self:{owner}';")[-1] == '1'
assert sql(f"select count(*) from public.conversation_members where conversation_id='{cid}';")[-1] == '1'
sql(f"delete from public.conversations where id='{cid}';delete from auth.users where id='{owner}';")
print('PASS: concurrent self-chat creation returns one durable single-member conversation')
