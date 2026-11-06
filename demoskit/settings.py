"""Environment helpers: .env loading and the Claude billing/auth env for agent subprocesses."""
import os
import re
from pathlib import Path
from typing import Dict

AGENT_ENV_KEYS = ("ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN")


def load_dotenv(path: Path) -> None:
    """KEY=VALUE lines into os.environ, without overriding what is already set. Values are
    literal (no shell sourcing, no expansion); one pair of surrounding quotes is stripped."""
    path = Path(path)
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", line)
        if m and not line.lstrip().startswith("#"):
            value = m.group(2)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            os.environ.setdefault(m.group(1), value)


def agent_env(prefix: str = "") -> Dict[str, str]:
    """The env that decides which account an agent's Claude Code subprocess bills to.

    Reads {prefix}ANTHROPIC_API_KEY, {prefix}CLAUDE_CONFIG_DIR and {prefix}CLAUDE_CODE_OAUTH_TOKEN
    and maps each one that is set to its unprefixed name. prefix="SDD_" gives DemosOs's AGENT_ENV.
    """
    return {key: os.environ[prefix + key] for key in AGENT_ENV_KEYS if os.getenv(prefix + key)}
