"""Runs snowflake/demo/live_demo.sql statement by statement, exactly as the presenter will, with the same pauses.
Used by the GitHub workflow demo-rehearsal (tag != live, so the real demo files stay unused)."""
import json, os, re, subprocess, sys, time

tag = sys.argv[1]
conn = os.environ["CONN"].split()
sql = open("snowflake/demo/live_demo.sql").read().replace("_live", f"_{tag}")

stmts, buf, pause = [], [], 0
for line in sql.splitlines():
    s = line.strip()
    if s.startswith("--"):
        if "wait ~30 s" in s:
            pause = 45
        if "STEP 5" in s or "~3 min later" in s:
            pause = 75
        continue
    if not s:
        continue
    buf.append(line)
    if s.endswith(";"):
        stmts.append((pause, "\n".join(buf)))
        buf, pause = [], 0

for pause, stmt in stmts:
    if pause:
        print(f"\n... waiting {pause}s (the presenter talks meanwhile)", flush=True)
        time.sleep(pause)
    print("\n>>> " + stmt.splitlines()[0][:150], flush=True)
    r = subprocess.run(["snow", "sql", "--enable-templating", "NONE", *conn, "-q", stmt], capture_output=True, text=True)
    print(r.stdout[-3000:], r.stderr[-1500:], flush=True)
    if r.returncode != 0:
        sys.exit(f"statement failed: {stmt[:200]}")
