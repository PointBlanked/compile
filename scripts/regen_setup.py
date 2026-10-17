# Owner: Maxwell. Regenerates setup_repo.sh from the tracked files. Run from the repo root: python3 scripts/regen_setup.py
import subprocess, os, base64
HEAD = '''#!/usr/bin/env bash
# Recreates the AutoVision Audio Engine repo from scratch, commits, and pushes.
# Usage: ./setup_repo.sh [target-dir]   (REMOTE_URL overrides the GitHub remote)
set -euo pipefail

TARGET="${1:-auto-vision-audio-engine}"
REMOTE_URL="${REMOTE_URL:-https://github.com/PointBlanked/compile.git}"

mkdir -p "$TARGET"
cd "$TARGET"
'''
TAIL = '''git init -q -b main
git add -A
git commit -q -m "Initial AutoVision Audio Engine scaffold"

if git remote | grep -q "^origin$"; then git remote set-url origin "$REMOTE_URL"; else git remote add origin "$REMOTE_URL"; fi
git push -u origin main
echo "Pushed to $REMOTE_URL"
'''
D = 'EOF_' + 'AVAE'  # built at runtime so this file can embed itself
files = sorted(f for f in subprocess.check_output(['git', 'ls-files', '--others', '--cached', '--exclude-standard']).decode().split()
               if f != 'setup_repo.sh')
out = [HEAD, 'mkdir -p ' + ' '.join(sorted({os.path.dirname(f) for f in files if os.path.dirname(f)})), '']
for f in files:
    data = open(f, 'rb').read()
    assert D.encode() not in data, f
    if f.endswith('.png'):
        out += [f"base64 --decode > '{f}' <<'{D}'", base64.b64encode(data).decode(), D, '']
    else:
        out += [f"cat > '{f}' <<'{D}'", data.decode().rstrip('\n'), D, '']
open('setup_repo.sh', 'w').write('\n'.join(out) + '\n' + TAIL)
