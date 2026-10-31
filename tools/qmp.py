import socket, json, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rw")
def rd():
    while True:
        m = json.loads(f.readline())
        if "event" not in m: return m
rd(); f.write(json.dumps({"execute":"qmp_capabilities"})+"\n"); f.flush(); rd()
for cmd in sys.argv[2:]:
    f.write(json.dumps({"execute":"human-monitor-command","arguments":{"command-line":cmd}})+"\n"); f.flush()
    print(f"### {cmd}\n" + rd().get("return",""))
