# Runs Saleor's migrations under a Postgres advisory lock, so web containers
# booting on several hosts at once take turns instead of racing.
#
# Waiting hosts poll pg_try_advisory_lock rather than block in
# pg_advisory_lock: a blocked call is an open transaction, and Saleor's
# CREATE INDEX CONCURRENTLY migrations wait for every open transaction to
# end, so the lock holder and the waiters would deadlock.
import os
import time

import django

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "saleor.settings")
django.setup()

from django.core.management import call_command  # noqa: E402
from django.db import connection  # noqa: E402

LOCK = 7_310_416  # any constant; the same on every host


def try_lock():
    with connection.cursor() as cursor:
        cursor.execute("SELECT pg_try_advisory_lock(%s)", [LOCK])
        return cursor.fetchone()[0]


while not try_lock():
    print("lab-saleor: another host is migrating, waiting", flush=True)
    time.sleep(2)
try:
    call_command("migrate", interactive=False)
finally:
    with connection.cursor() as cursor:
        cursor.execute("SELECT pg_advisory_unlock(%s)", [LOCK])
