"""The product's agents. Add them to make_os(agents=[...]) in main.py.

Example: a read-only agent over one directory (no Bash, no web, no host settings).

    from pathlib import Path
    from demoskit import claude_agent

    summarizer = claude_agent(
        "summarizer",
        description="Reads the documents folder and summarizes what it is asked about.",
        system_prompt="Answer only from the files you read. Cite file names.",
        model="sonnet",                 # "opus" / "sonnet" / "haiku" or a full model id
        read_only_dir=Path("data/docs"),
        max_turns=8,
    )
"""
