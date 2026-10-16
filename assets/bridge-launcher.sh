for _agentspace_python in python3 "$HOME/.local/bin/python3" /opt/homebrew/bin/python3 /usr/local/bin/python3 /opt/local/bin/python3 /usr/bin/python3; do
  if "$_agentspace_python" -c 'import sys,socket,zipfile,hashlib,json,concurrent.futures; sys.exit(sys.version_info < (3,9))' </dev/null >/dev/null 2>&1; then
    exec "$_agentspace_python" -c "$1"
  fi
done
printf '%s\n' 'python3: compatible interpreter not found (Python 3.9 or newer is required)' >&2
exit 127
