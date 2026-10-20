"""Prints the libraries in DIR that the binaries under ROOT load, directly or through each other
(otool -L, by file name: they're referenced as @rpath/…). make-app.sh --standalone copies just
those of VTK's (OCP links 57 of its 219 libraries; the rest is 230 MB the engine never loads).

    python3 linked_dylibs.py ROOT DIR
"""
import os
import subprocess
import sys

root, lib_dir = sys.argv[1], sys.argv[2]
todo = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs if f.endswith((".so", ".dylib"))]
need: set[str] = set()
while todo:
    out = subprocess.run(["otool", "-L", todo.pop()], capture_output=True, text=True).stdout
    for line in out.splitlines()[1:]:
        name = os.path.basename(line.strip().split(" ")[0])
        path = os.path.join(lib_dir, name)
        if name not in need and os.path.exists(path):
            need.add(name)
            todo.append(path)
print("\n".join(sorted(need)))
