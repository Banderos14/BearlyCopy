"""Prompt Relay Core: capture Claude Code hook events locally and export them.

Platform-independent core. The only macOS-specific piece is the pbcopy
clipboard backend in ``clipboard.py``. Standard library only; Python 3.9+.
"""

__version__ = "0.6.0"
