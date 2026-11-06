from pathlib import Path

from fastapi.testclient import TestClient

from demoskit import agent_env, claude_agent, load_dotenv, make_os


def test_claude_agent_closed_defaults():
    agent = claude_agent("note-taker", system_prompt="hi", env={})
    assert agent.tools == []
    assert agent.setting_sources == []
    assert agent.allowed_tools == []
    assert agent.disallowed_tools == ["Bash", "WebFetch", "WebSearch"]
    assert agent.permission_mode == "dontAsk"
    assert agent.model == "sonnet"
    assert agent.name == "Note Taker"
    assert agent.retries == 0 and agent.delay_between_retries == 30 and agent.exponential_backoff is True
    opts = agent._build_options()
    assert opts.tools == [] and opts.setting_sources == [] and opts.env == {}


def test_read_only_dir(tmp_path):
    agent = claude_agent("reader", system_prompt="read", read_only_dir=tmp_path, allowed_tools=["Bash(ls:*)"])
    root = tmp_path.resolve()
    assert agent.tools == ["Read", "Glob", "Grep"]
    assert agent.allowed_tools == ["Bash(ls:*)", f"Read(/{root}/**)", f"Glob(/{root}/**)", f"Grep(/{root}/**)"]
    assert agent.allowed_tools[1].startswith("Read(//")
    assert agent.cwd == str(root)


def test_env_and_buffer_reach_options(monkeypatch):
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "tok")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    agent = claude_agent("a", system_prompt="x", max_buffer_size=1234)
    opts = agent._build_options()
    assert opts.env == {"CLAUDE_CODE_OAUTH_TOKEN": "tok"}
    assert opts.max_buffer_size == 1234


def test_agent_env_prefix(monkeypatch):
    for k in ("ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN"):
        monkeypatch.delenv(k, raising=False)
        monkeypatch.delenv("SDD_" + k, raising=False)
    monkeypatch.setenv("SDD_ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setenv("SDD_CLAUDE_CONFIG_DIR", "/tmp/cfg")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "not-this-one")
    assert agent_env("SDD_") == {"ANTHROPIC_API_KEY": "sk-test", "CLAUDE_CONFIG_DIR": "/tmp/cfg"}
    assert agent_env() == {"ANTHROPIC_API_KEY": "not-this-one"}


def test_load_dotenv(tmp_path, monkeypatch):
    monkeypatch.setenv("KEEP", "set")
    monkeypatch.delenv("A", raising=False)
    monkeypatch.delenv("B", raising=False)
    env = tmp_path / ".env"
    env.write_text("# c\nA='x $HOME'\nexport B=2\nKEEP=other\n")
    load_dotenv(env)
    import os
    assert os.environ["A"] == "x $HOME" and os.environ["B"] == "2" and os.environ["KEEP"] == "set"
    load_dotenv(tmp_path / "missing.env")


def test_make_os_serves_health(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENTOS_DB", str(tmp_path / "sub" / "agentos.db"))
    monkeypatch.setenv("OS_SECURITY_KEY", "secret")
    agent_os = make_os(id="test-os", description="Test")
    assert agent_os.settings.os_security_key == "secret"
    assert (tmp_path / "sub").is_dir()
    with TestClient(agent_os.get_app()) as client:
        assert client.get("/health").status_code == 200
        assert client.get("/agents").status_code == 401
        assert client.get("/agents", headers={"Authorization": "Bearer secret"}).status_code == 200
