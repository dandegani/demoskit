"""claude_agent: a ClaudeAgent with safe defaults (no host settings, no built-in tools)."""
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, Optional, Union

from agno.agents.claude import ClaudeAgent

from demoskit.settings import agent_env

READ_ONLY_TOOLS = ("Read", "Glob", "Grep")
# Permission modes in which Claude Code never asks: dontAsk denies, bypassPermissions allows.
NEVER_ASKS = ("dontAsk", "bypassPermissions")


def _denier(allowed_tools: Iterable[str]) -> Callable[..., Any]:
    """can_use_tool for approvals=False: a call nothing allowed is denied, never put to a person.

    The message names the denied call and what is still allowed, so the agent tries an allowed
    form instead of concluding that the whole tool is off (2026-11-08: "Bash is not allowed"
    made SDD agents stop running git commit/push, which were allowed)."""
    bash_rules = [t[len("Bash(") : -1] for t in allowed_tools if t.startswith("Bash(") and t.endswith(")")]

    async def deny(tool_name: str, tool_input: Dict[str, Any], context: Any) -> Any:
        from claude_agent_sdk import PermissionResultDeny

        if tool_name == "Bash":
            command = str((tool_input or {}).get("command", "")).strip()
            command = command if len(command) <= 200 else command[:200] + "..."
            if bash_rules:
                message = (
                    f"Not run: this Bash command matches none of your allowed rules: {command!r}. "
                    "Bash itself still works: commands that match a rule run without asking. "
                    f"Allowed rules: {', '.join(bash_rules)}. In a chain (&&, ;, |) every part must match. "
                    "Use Edit/Write for file changes, not sed or scripts. Nobody approves other commands at run time."
                )
            else:
                message = f"Not run: Bash is not allowed for this agent ({command!r}). Nobody approves requests at run time."
        else:
            message = f"Not run: {tool_name} is not allowed for this agent. Nobody approves requests at run time."
        return PermissionResultDeny(message=message)

    return deny


def _add(items: list, extra: Iterable[str]) -> list:
    return items + [x for x in extra if x not in items]


def claude_agent(
    id: str,
    *,
    system_prompt: Any,
    model: str = "sonnet",
    description: str = "",
    name: Optional[str] = None,
    tools: Iterable[str] = (),
    allowed_tools: Iterable[str] = (),
    disallowed_tools: Iterable[str] = ("Bash", "WebFetch", "WebSearch"),
    read_only_dir: Optional[Union[str, Path]] = None,
    cwd: Optional[Union[str, Path]] = None,
    setting_sources: Iterable[str] = (),
    permission_mode: str = "dontAsk",
    max_turns: int = 8,
    output_schema: Any = None,
    mcp_servers: Any = None,
    db: Any = None,
    env: Optional[Dict[str, str]] = None,
    retries: int = 0,
    delay_between_retries: int = 30,
    exponential_backoff: bool = True,
    max_buffer_size: Optional[int] = None,
    approvals: bool = False,
    **extra: Any,
) -> ClaudeAgent:
    """Build an agno ClaudeAgent (Claude Code as a subprocess) with closed defaults.

    model: passed to Claude Code unchanged. It accepts the aliases "opus", "sonnet", "haiku"
        and full model ids; no id is invented or rewritten here.
    tools: the built-in tools that exist for this agent. () means [] = every built-in tool off.
    allowed_tools: calls approved without asking (permission rules, e.g. "Bash(git log:*)").
        With permission_mode="dontAsk" everything else is denied.
    read_only_dir: sugar for a read-only agent over one directory: adds Read/Glob/Grep to tools,
        "Read(//<abs dir>/**)" (and the same for Glob/Grep) to allowed_tools, and sets cwd to it.
        "//" is Claude Code's prefix for an absolute filesystem path in a permission rule.
    setting_sources: () means [] = never load the host's user/project/local Claude settings.
    env: billing/auth env for the subprocess. None = agent_env() (unprefixed variables).
        The SDK merges it OVER the server's full environment, so it can override or blank a
        key ("" = unset for ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN) but cannot remove one:
        env={} means "inherit everything", not an empty env. See demoskit.settings.agent_env.
    retries (default 0: an agent with side effects must not be re-run silently), delay_between_retries,
        exponential_backoff: agno BaseExternalAgent fields; failures
        that would fail again (auth, billing, invalid request, max_turns) are not retried.
    max_buffer_size: ClaudeAgentOptions.max_buffer_size (bytes of one SDK message), None = SDK default.
    approvals: what happens to a tool call that permission_mode and allowed_tools leave undecided
        (only in a mode that asks, e.g. "acceptEdits"; "dontAsk" and "bypassPermissions" never ask).
        False (default): it is denied and the agent carries on, as on agno 3.1.6; an unattended run
        never waits on a person. True: agno >= 3.1.12 pauses the run on it as an AgentOS approval
        (needs db; waits up to the agent's hitl_timeout, default 900 s).
    extra: any other ClaudeAgent field (max_budget_usd, skills, strict_mcp_config, ...).
    """
    from claude_agent_sdk import ClaudeAgentOptions

    tools = list(tools)
    allowed_tools = list(allowed_tools)
    if read_only_dir is not None:
        root = Path(read_only_dir).resolve()
        tools = _add(tools, READ_ONLY_TOOLS)
        allowed_tools = _add(allowed_tools, [f"{t}(/{root}/**)" for t in READ_ONLY_TOOLS])
        cwd = root
    options_kwargs: Dict[str, Any] = {"env": dict(agent_env() if env is None else env)}
    if max_buffer_size is not None:
        options_kwargs["max_buffer_size"] = max_buffer_size
    asks = permission_mode not in NEVER_ASKS
    if approvals and (db is None or not asks):
        raise ValueError("approvals=True needs db and a permission_mode that asks (not dontAsk/bypassPermissions)")
    if asks and not approvals:
        # agno routes Claude Code's permission prompts into AgentOS approvals unless the
        # options carry their own can_use_tool (ClaudeAgent._uses_native_hitl).
        options_kwargs["can_use_tool"] = _denier(allowed_tools)
    return ClaudeAgent(
        id=id,
        name=name or id.replace("-", " ").replace("_", " ").title(),
        description=description,
        model=model,
        system_prompt=system_prompt,
        tools=tools,
        allowed_tools=allowed_tools,
        disallowed_tools=list(disallowed_tools),
        permission_mode=permission_mode,
        setting_sources=list(setting_sources),
        cwd=str(cwd) if cwd is not None else None,
        max_turns=max_turns,
        output_schema=output_schema,
        mcp_servers=mcp_servers,
        db=db,
        retries=retries,
        delay_between_retries=delay_between_retries,
        exponential_backoff=exponential_backoff,
        options=ClaudeAgentOptions(**options_kwargs),
        **extra,
    )
