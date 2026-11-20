import json
import os
import sys
import time

mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
if mode == "bad-ready":
    print('{"ready":false}', flush=True)
elif mode == "malformed-ready":
    print('not json', flush=True)
elif mode == "exit":
    sys.exit(1)
else:
    print(json.dumps({"ready": True}), flush=True)
for line in sys.stdin:
    value = json.loads(line)
    if mode == "oversize":
        print('x' * 65538, flush=True)
        continue
    if "hold" in value:
        with open(value["hold"], "w") as file:
            file.write(str(os.getpid()))
        time.sleep(60)
    print(json.dumps({"pid": os.getpid(), "text": value.get("text", "")}), flush=True)
