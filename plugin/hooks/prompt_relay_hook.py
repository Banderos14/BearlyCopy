"""Plugin hook entry point: imports the handler from this plugin root.

Run by hooks/run-hook as ``python -I -S prompt_relay_hook.py``. In isolated
mode the script directory is not on sys.path and PYTHON* variables are
ignored, so the package is imported from this plugin root only. Any failure
here still exits 0 with empty stdout (CLAUDE.md, invariant 1).
"""

import os
import sys

try:
    if sys.version_info < (3, 9):
        raise RuntimeError("python_too_old")
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
    from prompt_relay.hook import main as hook_main
except BaseException as exc:  # noqa: B902 - deliberately broad
    try:
        sys.stderr.write("prompt-relay: startup_failed:" + type(exc).__name__ + "\n")
    except BaseException:
        pass
    sys.exit(0)

sys.exit(hook_main())
