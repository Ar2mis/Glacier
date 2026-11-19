#!/usr/bin/env python3
"""Render our limited Markdown policy/support documents without remote dependencies."""
from pathlib import Path
import argparse
import html
import re

ROOT=Path(__file__).resolve().parents[1]
def inline(text):
    text=html.escape(text)
    text=re.sub(r'\[([^\]]+)\]\(([^)]+)\)',lambda m: '<a href="'+m[2].replace('PRIVACY_POLICY.md','privacy.html').replace('SUPPORT.md','support.html')+'">'+m[1]+'</a>',text)
    text=re.sub(r'\*\*(.+?)\*\*',r'<strong>\1</strong>',text)
    return re.sub(r'`([^`]+)`',r'<code>\1</code>',text)
def render(markdown):
    blocks=[]
    for block in markdown.strip().split('\n\n'):
        if block.startswith('# '): blocks.append('<h1>'+inline(block[2:])+'</h1>')
        elif block.startswith('## '): blocks.append('<h2>'+inline(block[3:])+'</h2>')
        elif re.match(r'(?:- |\d+\. )',block):
            ordered=not block.startswith('- '); tag='ol' if ordered else 'ul'
            items=re.split(r'\n(?=(?:- |\d+\. ))',block)
            blocks.append('<'+tag+'>'+''.join('<li>'+inline(re.sub(r'^(?:- |\d+\. )','',item).replace('\n',' '))+'</li>' for item in items)+'</'+tag+'>')
        else: blocks.append('<p>'+inline(block.replace('\n',' '))+'</p>')
    return '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Glacier · '''+html.escape(markdown.splitlines()[0][2:])+'''</title><style>
:root {color-scheme:light} body{margin:0;background:#eef8ff;color:#18374b;font:17px/1.7 system-ui,sans-serif}main{max-width:780px;margin:48px auto;padding:32px;background:white;border:1px solid #c9e5f6;border-radius:20px}h1,h2{line-height:1.25}h2{margin-top:2em}a{color:#075b8e}nav{display:flex;gap:24px}code{overflow-wrap:anywhere}li{margin:.6em 0}@media(max-width:820px){main{margin:12px;padding:22px}}
</style></head><body><main><nav><a href="privacy.html">Privacy</a><a href="support.html">Support</a><a href="https://github.com/Ar2mis/Glacier">Source</a></nav>'''+''.join(blocks)+'</main></body></html>\n'
def files():
    result={'docs/'+name+'.html':render((ROOT/source).read_text()) for source,name in [('PRIVACY_POLICY.md','privacy'),('SUPPORT.md','support')]}
    result['docs/index.html']=result['docs/support.html'];result['docs/.nojekyll']=''
    return result
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    for path,content in files().items():
        p=ROOT/path
        if args.check:
            if not p.exists() or p.read_text()!=content: raise SystemExit('Regenerate support site: '+path)
        else: p.parent.mkdir(parents=True,exist_ok=True);p.write_text(content)
    print('PASS: privacy/support HTML matches Markdown')
