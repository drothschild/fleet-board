"""Render one role session log (stream-json .jsonl) as plain text.

Lines that are not stream-json objects (provider-script output) pass through unchanged; a half-written
last line is skipped; an empty log renders as "no output".
"""
import json

EMPTY = 'no output'


def _block(block):
    if not isinstance(block, dict):
        return str(block)
    kind = block.get('type')
    if kind == 'text':
        return block.get('text', '')
    if kind == 'tool_use':
        return 'tool call: %s\n%s' % (block.get('name', '?'), json.dumps(block.get('input', {}), indent=2))
    if kind == 'tool_result':
        content = block.get('content', '')
        if isinstance(content, list):
            content = '\n'.join(_block(c) for c in content)
        return 'tool result:\n%s' % content
    return ''


def _content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(x for x in (_block(b) for b in content) if x)
    return ''


def _event(event):
    kind = event.get('type')
    if kind in ('assistant', 'user'):
        text = _content((event.get('message') or {}).get('content'))
        if kind == 'user' and text and not text.startswith('tool result:'):
            return 'prompt:\n%s' % text
        return text
    if kind == 'result':
        return 'final report:\n%s' % (event.get('result') or '')
    return ''


def render(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.read().split('\n')
    last = max((i for i, l in enumerate(lines) if l.strip()), default=-1)
    out = []
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            if i == last and line.lstrip().startswith('{'):
                continue   # half-written last line
            out.append(line)
            continue
        if not isinstance(event, dict):
            out.append(line)
            continue
        text = _event(event)
        if text:
            out.append(text)
    return '\n'.join(out) + '\n' if out else EMPTY
