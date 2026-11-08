# demoskit

ספרייה קטנה של אבני בניין משותפות למוצרי Demos שבנויים על Agno 3.1.12 (AgentOS + ClaudeAgent),
ותבנית copier למוצר חדש. בלי framework ובלי שכבות: שתי פונקציות שמחזירות את אובייקטי Agno עצמם.

## שתי הפונקציות

- **`claude_agent(id, system_prompt=..., ...)`** מחזיר `ClaudeAgent` עם ברירות מחדל סגורות:
  אין כלים מובנים (`tools=[]`), לא נטענות הגדרות Claude של המכונה (`setting_sources=[]`),
  `permission_mode="dontAsk"`, בלי Bash/WebFetch/WebSearch, ו-`retries=0` (בלי ניסיון חוזר; backoff רק כשמגדירים retries).
  `read_only_dir=Path(...)` נותן Read/Glob/Grep רק בתוך התיקייה. `model` עובר כמו שהוא
  (`"opus"`/`"sonnet"`/`"haiku"` או מזהה מלא). החיוב (`env`) נלקח מ-`agent_env()`.
- **`make_os(id, agents=[...], ...)`** מחזיר `AgentOS` עם SQLite ב-`$AGENTOS_DB`
  (ברירת מחדל `data/agentos.db`), מפתח API מ-`$OS_SECURITY_KEY`, telemetry כבוי,
  ו-`on_route_conflict="error"`. ‏`serve(agent_os)` מריץ על `$AGENTOS_HOST:$AGENTOS_PORT`.
  כש-`$AGENTOS_HOST` אינו localhost/127.0.0.1/לא מוגדר (למשל `0.0.0.0` בקונטיינר) ואין מפתח,
  `make_os` נכשל ב-`RuntimeError`: API פתוח על כתובת חיצונית לא עולה. ‏`require_key=True/False` מכריע ידנית.

ועוד שני עזרים: `load_dotenv(path)` (שורות KEY=value מילוליות, לא דורס משתנים קיימים)
ו-`agent_env(prefix)` (‏`ANTHROPIC_API_KEY` / `CLAUDE_CONFIG_DIR` / `CLAUDE_CODE_OAUTH_TOKEN`, ראו למטה).

```bash
pip install "demoskit @ git+https://github.com/dandegani/demoskit@v0.3.1"          # או [postgres]
python -m pytest     # הבדיקות, בלי קריאות למודל
```

## התבנית

`template/` היא תבנית copier למוצר: Dockerfile עם Claude Code, ‏compose (ו-pgvector אם צריך),
overlay לייצור מאחורי ה-edge, CI (‏`make check`), כפתור deploy ב-GitHub עם rollback, ו-`tests/test_boot.py`
(האפליקציה עולה ו-`/health` מחזיר 200).

```bash
copier copy gh:dandegani/demoskit ~/new-product          # התג האחרון; ‎--vcs-ref <tag|HEAD>‎ לגרסה אחרת
copier copy --vcs-ref HEAD ~/demoskit ~/new-product      # מ-checkout מקומי (copier.yml בשורש הריפו)
```

`copier update` בתוך מוצר קיים מושך את שינויי התבנית (התשובות נשמרות ב-`.copier-answers.yml`).

## כלל השניים

קוד נכנס ל-demoskit רק כשיש לו משתמש שני. עד אז הוא נשאר במוצר שכתב אותו;
כשמוצר נוסף צריך אותו, מעבירים אותו לכאן ושני המוצרים עוברים להשתמש בגרסה המשותפת.

## מה לשים לב אליו ב-`claude_agent`

- `approvals=False` כברירת מחדל. ב-`permission_mode` ששואל (למשל `"acceptEdits"`), קריאה לכלי ש-`allowed_tools`
  לא מכריע נדחית והסוכן ממשיך, כמו ב-Agno 3.1.6. מ-Agno 3.1.12 סוכן עם `db` היה עוצר עליה ומחכה לאישור
  ב-AgentOS (עד `hitl_timeout`, ‏900 שניות), וריצה בלי אדם הייתה נתקעת. ‏`approvals=True` מפעיל את זה במכוון
  (צריך `db`). ב-`"dontAsk"` (ברירת המחדל) אין מה לאשר.
- `retries=0` כברירת מחדל. סוכן שיש לו תופעות לוואי (push, שליחת הודעה) לא רץ שוב בשקט. סוכן קריאה בלבד יכול לקבל `retries=2`.
- `env=None` פירושו `agent_env()`. ה-SDK **ממזג** את `env` מעל כל הסביבה של תהליך השרת
  (`{**os.environ, **options.env}`), כך שמפתח שלא מופיע ב-`env` עובר בירושה. **`env={}` אינו סביבה ריקה**:
  הוא "ירושה של הכול". אפשר לדרוס או לרוקן מפתח, אי אפשר להסיר אותו.
- `agent_env(prefix)`: כשאף אחד מ-`{prefix}ANTHROPIC_API_KEY` / `{prefix}CLAUDE_CONFIG_DIR` / `{prefix}CLAUDE_CODE_OAUTH_TOKEN`
  לא מוגדר, מחזיר `{}` (ירושה: ה-login של Claude Code במכונה, ברירת המחדל ב-WSL). כשלפחות אחד מוגדר,
  מחזיר אותו בשם בלי הקידומת, ו-`""` ל-`ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` שלא נבחרו, כדי
  שמפתח תועה ב-shell של השרת לא יחליף את שיטת החיוב שהמוצר בחר. Claude Code מתייחס ל-`""` באלה כאל
  לא מוגדר (נבדק ב-CLI 2.1.319). ‏`CLAUDE_CONFIG_DIR` לא מרוקן לעולם: `""` שם הוא תיקייה יחסית ל-cwd
  ("Not logged in"), ולכן הוא עובר בירושה כשלא נבחר; הוא רק בוחר login שמור, ומפתח/טוקן שנבחרו קודמים לו.
