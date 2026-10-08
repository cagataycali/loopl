"""mkdocs hook: drop the `// snippet: compile…` marker line from rendered code blocks.
docs/check_snippets.sh reads the raw Markdown, so the gate still sees every tag."""
import re
_TAG = re.compile(r"^[ \t]*//[ \t]*snippet:[ \t]*compile(?:\([^)]*\))?[ \t]*\n", re.M)

def on_page_markdown(markdown, **kwargs):
    return _TAG.sub("", markdown)
