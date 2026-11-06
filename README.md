# demoskit

ספרייה קטנה של אבני בניין משותפות למוצרי Demos שבנויים על Agno 3.1.6 (AgentOS + ClaudeAgent),
ותבנית copier למוצר חדש. בלי framework ובלי שכבות: שתי פונקציות שמחזירות את אובייקטי Agno עצמם.

## שתי הפונקציות

- **`claude_agent(id, system_prompt=..., ...)`** מחזיר `ClaudeAgent` עם ברירות מחדל סגורות:
  אין כלים מובנים (`tools=[]`), לא נטענות הגדרות Claude של המכונה (`setting_sources=[]`),
  `permission_mode="dontAsk"`, בלי Bash/WebFetch/WebSearch, ו-retries עם backoff.
  `read_only_dir=Path(...)` נותן Read/Glob/Grep רק בתוך התיקייה. `model` עובר כמו שהוא
  (`"opus"`/`"sonnet"`/`"haiku"` או מזהה מלא). החיוב (`env`) נלקח מ-`agent_env()`.
- **`make_os(id, agents=[...], ...)`** מחזיר `AgentOS` עם SQLite ב-`$AGENTOS_DB`
  (ברירת מחדל `data/agentos.db`), מפתח API מ-`$OS_SECURITY_KEY`, telemetry כבוי,
  ו-`on_route_conflict="error"`. ‏`serve(agent_os)` מריץ על `$AGENTOS_HOST:$AGENTOS_PORT`.

ועוד שני עזרים: `load_dotenv(path)` (שורות KEY=value מילוליות, לא דורס משתנים קיימים)
ו-`agent_env(prefix)` (‏`ANTHROPIC_API_KEY` / `CLAUDE_CONFIG_DIR` / `CLAUDE_CODE_OAUTH_TOKEN`).

```bash
pip install "demoskit @ git+https://github.com/dandegani/demoskit@v0.1.0"          # או [postgres]
python -m pytest     # הבדיקות, בלי קריאות למודל
```

## התבנית

`template/` היא תבנית copier למוצר: Dockerfile עם Claude Code, ‏compose (ו-pgvector אם צריך),
overlay לייצור מאחורי ה-edge, CI (‏`make check`), כפתור deploy ב-GitHub עם rollback, ו-`tests/test_boot.py`
(האפליקציה עולה ו-`/health` מחזיר 200).

```bash
copier copy /path/to/demoskit/template ~/new-product
```

## כלל השניים

קוד נכנס ל-demoskit רק כשיש לו משתמש שני. עד אז הוא נשאר במוצר שכתב אותו;
כשמוצר נוסף צריך אותו, מעבירים אותו לכאן ושני המוצרים עוברים להשתמש בגרסה המשותפת.
