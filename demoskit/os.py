"""make_os / serve: an AgentOS with the Demos defaults."""
import os
from pathlib import Path
from typing import Any, Iterable, Optional

from agno.db.sqlite import SqliteDb
from agno.os import AgentOS
from agno.os.settings import AgnoAPISettings

# AGENTOS_HOST values that keep the API on this machine; "" counts as unset.
LOOPBACK_HOSTS = ("", "localhost", "127.0.0.1")


def make_os(
    id: str,
    *,
    description: str = "",
    agents: Iterable[Any] = (),
    workflows: Iterable[Any] = (),
    db: Any = None,
    knowledge: Iterable[Any] = (),
    lifespan: Any = None,
    base_app: Any = None,
    security_key: Optional[str] = None,
    cors_origins: Iterable[str] = (),
    telemetry: bool = False,
    mcp: Any = False,
    require_key: Optional[bool] = None,
    **extra: Any,
) -> AgentOS:
    """An AgentOS with a SQLite db by default and telemetry off.

    db: None = SqliteDb at $AGENTOS_DB (default data/agentos.db); its directory is created.
    security_key: bearer token for the API. None = $OS_SECURITY_KEY. Agno 3.1.12 has no
        AgentOS(security_key=) parameter; the key lives in AgnoAPISettings.os_security_key
        (which also reads OS_SECURITY_KEY from the env), so it is passed as settings=.
        /health stays open either way.
    require_key: whether an empty security key is an error. None (default) = required unless
        $AGENTOS_HOST is unset, "localhost" or "127.0.0.1" (an API on a non-loopback address
        must not be open); True/False force it either way. Raises RuntimeError when required
        and missing. Ignored when extra carries its own settings=.
    cors_origins: extra allowed origins (AgentOS cors_allowed_origins; agno adds its own domains).
    on_route_conflict="error": a base_app route that collides with an AgentOS route fails at
        startup instead of being silently shadowed. Override through extra.
    """
    if db is None:
        db_file = Path(os.getenv("AGENTOS_DB", "data/agentos.db"))
        db_file.parent.mkdir(parents=True, exist_ok=True)
        db = SqliteDb(db_file=str(db_file))
    if "settings" not in extra:
        key = security_key or os.getenv("OS_SECURITY_KEY") or None
        if require_key is None:
            require_key = os.getenv("AGENTOS_HOST", "localhost") not in LOOPBACK_HOSTS
        if require_key and not key:
            raise RuntimeError("OS_SECURITY_KEY is required when AGENTOS_HOST is not loopback")
        extra["settings"] = AgnoAPISettings(os_security_key=key)
    extra.setdefault("on_route_conflict", "error")
    return AgentOS(
        id=id,
        description=description,
        agents=list(agents) or None,
        workflows=list(workflows) or None,
        knowledge=list(knowledge) or None,
        db=db,
        lifespan=lifespan,
        base_app=base_app,
        cors_allowed_origins=list(cors_origins) or None,
        telemetry=telemetry,
        mcp=mcp,
        **extra,
    )


def serve(agent_os: AgentOS, module_app: str = "main:app", **kwargs: Any) -> None:
    """Run the OS with uvicorn on $AGENTOS_HOST:$AGENTOS_PORT (default localhost:8000).
    module_app is the import string of the module-level app (needed for reload/workers)."""
    host = os.getenv("AGENTOS_HOST", "localhost")
    port = int(os.getenv("AGENTOS_PORT", "8000"))
    agent_os.serve(app=module_app, host=host, port=port, **kwargs)
