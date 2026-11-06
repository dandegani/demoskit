"""Environment helpers: .env loading and the Claude billing/auth env for agent subprocesses."""
import os
import re
from pathlib import Path
from typing import Dict

AGENT_ENV_KEYS = ("ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN")
# The keys agent_env blanks with "" when the product chose another method; "" works as unset
# for these two only (see agent_env).
BLANKABLE_KEYS = ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")


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

    Reads {prefix}ANTHROPIC_API_KEY, {prefix}CLAUDE_CONFIG_DIR and {prefix}CLAUDE_CODE_OAUTH_TOKEN.
    prefix="SDD_" gives DemosOs's AGENT_ENV.

    The result goes to ClaudeAgentOptions.env, which the SDK MERGES OVER the full environment of
    the server process (claude_agent_sdk subprocess_cli: {**os.environ, ..., **options.env}).
    A key left out of the dict is therefore inherited, not absent; env={} means "inherit
    everything", never an empty env.

    - None of the prefixed keys set: {} -> the subprocess inherits the server's env, i.e. this
      machine's Claude Code login (or whatever unprefixed keys the server shell has).
    - At least one set: each set key is mapped to its unprefixed name, and the credential keys
      that are not set (ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN) are mapped to "", so a stray
      unprefixed key in the server's shell cannot override the method the product chose.
      Claude Code treats an empty ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN as unset (checked
      with CLI 2.1.319: apiKeySource "none", subscription login used).
    - CLAUDE_CONFIG_DIR is never blanked: Claude Code takes CLAUDE_CONFIG_DIR="" as a config
      dir relative to the cwd ("Not logged in"). When the prefixed one is not set, the server's
      CLAUDE_CONFIG_DIR (if any) is inherited; it only chooses the stored login, which an API
      key or OAuth token set here takes precedence over.
    """
    chosen = {key: os.environ[prefix + key] for key in AGENT_ENV_KEYS if os.getenv(prefix + key)}
    if not chosen:
        return {}
    return {**{key: "" for key in BLANKABLE_KEYS}, **chosen}
