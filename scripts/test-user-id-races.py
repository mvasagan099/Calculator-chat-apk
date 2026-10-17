#!/usr/bin/env python3
"""Real concurrent PostgreSQL signup-trigger test, disposable test container only."""
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

container = sys.argv[1]


def sql(statement):
    return subprocess.run(
        ['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-At', '-v', 'ON_ERROR_STOP=1'],
        input=statement, capture_output=True, text=True, timeout=30,
    )


def register(number):
    intent = f'12000000-0000-0000-0000-0000000000{number:02}'
    owner = f'12000000-0000-0000-0000-0000000000{number+10:02}'
    return sql(f"""begin;
select public.account_signup_intent('{intent}','concurrent_id','Concurrent',
 array(select md5(i::text)||md5(i::text) from generate_series(1,8)i));
insert into auth.users(id,raw_app_meta_data) values('{owner}',
 '{{"calculator_signup_intent":"{intent}"}}');
commit;""")


with ThreadPoolExecutor(max_workers=2) as executor:
    results = list(executor.map(register, [21, 22]))
assert sorted(r.returncode == 0 for r in results) == [False, True], 'Concurrent uniqueness failed'
check = sql("select count(*) from public.profiles where username='concurrent_id';")
assert check.returncode == 0 and check.stdout.strip() == '1', 'Duplicate profile committed'
check = sql("select count(*) from auth.users where id in ('12000000-0000-0000-0000-000000000031','12000000-0000-0000-0000-000000000032');")
assert check.returncode == 0 and check.stdout.strip() == '1', 'Losing signup left orphan Auth user'
cleanup = sql("delete from auth.users where id in ('12000000-0000-0000-0000-000000000031','12000000-0000-0000-0000-000000000032');")
assert cleanup.returncode == 0
print('PASS: concurrent signup commits exactly one Auth user/profile/recovery set')
